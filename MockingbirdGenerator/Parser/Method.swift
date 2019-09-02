//
//  Method.swift
//  MockingbirdCli
//
//  Created by Andrew Chang on 8/10/19.
//  Copyright © 2019 Bird Rides, Inc. All rights reserved.
//

import Foundation
import SourceKittenFramework

struct MethodParameter: Hashable {
  let name: String
  let argumentLabel: String?
  let typeName: String
  let kind: SwiftDeclarationKind
  let attributes: Attributes
  
  init?(from dictionary: StructureDictionary,
        argumentLabel: String?,
        parameterIndex: Int,
        rawDeclaration: Substring?,
        rawType: RawType,
        moduleNames: [String],
        rawTypeRepository: RawTypeRepository,
        typealiasRepository: TypealiasRepository) {
    guard let kind = SwiftDeclarationKind(from: dictionary), kind == .varParameter,
      let rawTypeName = dictionary[SwiftDocKey.typeName.rawValue] as? String
      else { return nil }
    // It's possible for protocols to define parameters with only the argument label and no name.
    self.name = dictionary[SwiftDocKey.name.rawValue] as? String ?? "param\(parameterIndex+1)"
    self.kind = kind
    self.argumentLabel = argumentLabel
    
    let containingTypeNames = rawType.containingTypeNames[...] + [rawType.name]
    let containingScopes = rawType.containingScopes[...] + [rawType.name]
    var typeName = rawTypeName
    var actualTypeName = typeName
    if let qualifiedTypeNames = rawTypeRepository
      .nearestInheritedType(named: rawTypeName,
                            moduleNames: moduleNames,
                            referencingModuleName: rawType.parsedFile.moduleName,
                            containingTypeNames: containingTypeNames)?
      .findBaseRawType()?
      .qualifiedModuleNames(from: rawTypeName, context: containingScopes) {
      typeName = qualifiedTypeNames.contextQualified
      actualTypeName = typealiasRepository
        .actualTypeName(for: qualifiedTypeNames.moduleQualified,
                        rawTypeRepository: rawTypeRepository,
                        moduleNames: moduleNames,
                        referencingModuleName: rawType.parsedFile.moduleName,
                        containingTypeNames: containingTypeNames)
    }
    var attributes = Attributes.create(from: dictionary)
    if rawTypeName.range(of: #"\binout\b"#,
                         options: .regularExpression)?.lowerBound == actualTypeName.startIndex {
      attributes.insert(.`inout`)
      typeName = String(typeName.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if actualTypeName.containsUngrouped("->") {
      attributes.insert(.closure)
    }
    if rawTypeName.containsUngrouped("@autoclosure") {
      attributes.insert(.autoclosure)
      if !typeName.containsUngrouped("@autoclosure") { // Re-hydrate fully qualified type names.
        typeName = "@autoclosure " + typeName
      }
    }
    if rawTypeName.containsUngrouped("@escaping") {
      attributes.insert(.escaping)
      if !typeName.containsUngrouped("@escaping") { // Re-hydrate fully qualified type names.
        typeName = "@escaping " + typeName
      }
    }
    if rawDeclaration?.hasSuffix("...") == true {
      attributes.insert(.variadic)
    }
    
    self.typeName = typeName
    self.attributes = attributes
  }
}

struct Method: Hashable, Comparable {
  let name: String
  let returnTypeName: String
  let isInitializer: Bool
  let kind: SwiftDeclarationKind
  let genericTypes: [GenericType]
  let genericConstraints: [String]
  let parameters: [MethodParameter]
  let attributes: Attributes
  
  /// A hashable version of Method that's unique according to Swift generics when subclassing.
  /// https://forums.swift.org/t/cannot-override-more-than-one-superclass-declaration/22213
  struct Reduced: Hashable {
    let name: String
    let returnTypeName: String
    let genericTypes: [GenericType.Reduced]
    let parameters: [MethodParameter]
    init(from method: Method) {
      self.name = method.name
      self.returnTypeName = method.returnTypeName
      self.genericTypes = method.genericTypes.map({ GenericType.Reduced(from: $0) })
      self.parameters = method.parameters
    }
  }
  
  func hash(into hasher: inout Hasher) {
    hasher.combine(name)
    hasher.combine(returnTypeName)
    hasher.combine(kind.typeScope == .instance)
    hasher.combine(genericTypes)
    hasher.combine(genericConstraints)
    hasher.combine(parameters)
  }
  
  static func ==(lhs: Method, rhs: Method) -> Bool {
    return lhs.hashValue == rhs.hashValue
  }
  
  private let sortableIdentifier: String
  static func < (lhs: Method, rhs: Method) -> Bool {
    return lhs.sortableIdentifier < rhs.sortableIdentifier
  }
  
  init?(from dictionary: StructureDictionary,
        rootKind: SwiftDeclarationKind,
        rawType: RawType,
        moduleNames: [String],
        rawTypeRepository: RawTypeRepository,
        typealiasRepository: TypealiasRepository) {
    guard let kind = SwiftDeclarationKind(from: dictionary), kind.isMethod,
      // Can't override static method declarations in classes.
      kind.typeScope == .instance
      || kind.typeScope == .class
      || (kind.typeScope == .static && rootKind == .protocol)
      else { return nil }
    
    guard let name = dictionary[SwiftDocKey.name.rawValue] as? String, name != "deinit",
      let accessLevel = AccessLevel(from: dictionary), accessLevel.isMockable
      else { return nil }
    
    var attributes = Attributes.create(from: dictionary)
    guard !attributes.contains(.final) else { return nil }
    let isInitializer = name.hasPrefix("init(")
    
    var rawParametersDeclaration: Substring?
    var genericConstraints = [String]()
    let source = rawType.parsedFile.file.contents
    if let declaration = SourceSubstring.key.extract(from: dictionary, contents: source) {
      let parametersEndIndex = declaration.firstIndex(of: ")")
      if let startIndex = declaration.firstIndex(of: "("), let endIndex = parametersEndIndex {
        rawParametersDeclaration = declaration[startIndex..<endIndex]
        
        if isInitializer {
          let failable = declaration[declaration.index(before: startIndex)..<startIndex]
          if failable == "?" {
            attributes.insert(.failable)
          } else if failable == "!" {
            attributes.insert(.unwrappedFailable)
          }
        }
      }
      let returnAttributesStartIndex = parametersEndIndex ?? declaration.startIndex
      let returnAttributesEndIndex = declaration.firstIndex(of: "-") ?? declaration.endIndex
      let returnAttributes = declaration[returnAttributesStartIndex..<returnAttributesEndIndex]
      if returnAttributes.range(of: #"\bthrows\b"#, options: .regularExpression) != nil {
        attributes.insert(.throws)
      }
    }
    if let nameSuffix = SourceSubstring.nameSuffixUpToBody.extract(from: dictionary, contents: source) {
      if let whereRange = nameSuffix.range(of: #"\bwhere\b"#, options: .regularExpression) {
        genericConstraints = nameSuffix[whereRange.upperBound..<nameSuffix.endIndex]
          .substringComponents(separatedBy: ",")
          .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        genericConstraints = GenericType
          .qualifyConstraintTypes(constraints: genericConstraints,
                                  containingType: rawType,
                                  moduleNames: moduleNames,
                                  rawTypeRepository: rawTypeRepository)
      }
    }
    self.attributes = attributes
    self.genericConstraints = genericConstraints
    self.isInitializer = isInitializer
    
    self.name = name
    self.kind = kind
    
    let containingTypeNames = rawType.containingTypeNames[...] + [rawType.name]
    let containingScopes = rawType.containingScopes[...] + [rawType.name]
    let returnTypeName = dictionary[SwiftDocKey.typeName.rawValue] as? String ?? "Void"
    let qualifiedReturnTypeNames = rawTypeRepository
      .nearestInheritedType(named: returnTypeName,
                            moduleNames: moduleNames,
                            referencingModuleName: rawType.parsedFile.moduleName,
                            containingTypeNames: containingTypeNames)?
      .findBaseRawType()?
      .qualifiedModuleNames(from: returnTypeName, context: containingScopes)
    self.returnTypeName = qualifiedReturnTypeNames?.contextQualified ?? returnTypeName
    
    let substructure = dictionary[SwiftDocKey.substructure.rawValue] as? [StructureDictionary] ?? []
    self.genericTypes = substructure.compactMap({ structure -> GenericType? in
      guard let genericType = GenericType(from: structure,
                                          rawType: rawType,
                                          moduleNames: moduleNames,
                                          rawTypeRepository: rawTypeRepository) else { return nil }
      return genericType
    })
    
    var parameters = [MethodParameter]()
    let labels = name.argumentLabels
    if !labels.isEmpty {
      var parameterIndex = 0
      let rawDeclarations = rawParametersDeclaration?.substringComponents(separatedBy: ",")
      parameters = substructure.compactMap({
        let rawDeclaration = rawDeclarations?.get(parameterIndex)
        guard let parameter = MethodParameter(from: $0,
                                              argumentLabel: labels[parameterIndex],
                                              parameterIndex: parameterIndex,
                                              rawDeclaration: rawDeclaration,
                                              rawType: rawType,
                                              moduleNames: moduleNames,
                                              rawTypeRepository: rawTypeRepository,
                                              typealiasRepository: typealiasRepository)
          else { return nil }
        parameterIndex += 1
        return parameter
      })
    }
    self.parameters = parameters
    
    if rawType.parsedFile.shouldMock {
      self.sortableIdentifier = [
        self.name,
        self.genericTypes.map({ "\($0.name):\($0.inheritedTypes)" }).joined(separator: ","),
        self.parameters
          .map({ "\($0.argumentLabel ?? ""):\($0.name):\($0.typeName)" })
          .joined(separator: ","),
        self.returnTypeName,
        self.genericConstraints.joined(separator: ",")
      ].joined(separator: "|")
    } else {
      self.sortableIdentifier = name
    }
  }
}

private extension String {
  var argumentLabels: [String?] {
    guard let startIndex = firstIndex(of: "("),
      let stopIndex = firstIndex(of: ")") else { return [] }
    let arguments = self[index(after: startIndex)..<stopIndex]
    return arguments.substringComponents(separatedBy: ":").map({ $0 != "_" ? String($0) : nil })
  }
}