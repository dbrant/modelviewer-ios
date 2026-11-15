//
//  FbxModelTests.swift
//  ModelViewerTests
//

import Foundation
import Testing
import Compression
@testable import ModelViewer

struct FbxModelTests {
    private static let tolerance: Float = 1e-5
    private static let image = Data([0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10, 1, 2, 3, 4, 5])

    // A quad in the XY plane, facing +Z, in a file whose Z axis is up and whose front is -Y (as from 3ds Max).
    private static let asciiQuad = """
        ; FBX 7.4.0 project file
        ; ----------------------------------------------------
        FBXHeaderExtension:  {
        \tFBXHeaderVersion: 1003
        \tFBXVersion: 7400
        }
        GlobalSettings:  {
        \tVersion: 1000
        \tProperties70:  {
        \t\tP: "UpAxis", "int", "Integer", "",2
        \t\tP: "UpAxisSign", "int", "Integer", "",1
        \t\tP: "FrontAxis", "int", "Integer", "",1
        \t\tP: "FrontAxisSign", "int", "Integer", "",-1
        \t\tP: "CoordAxis", "int", "Integer", "",0
        \t\tP: "CoordAxisSign", "int", "Integer", "",1
        \t}
        }

        ; Object properties
        ;------------------------------------------------------------------
        Objects:  {
        \tGeometry: 100, "Geometry::Quad", "Mesh" {
        \t\tVertices: *12 {
        \t\t\ta: 0,0,0,1.5e0,0,0,
        \t\t\t1.5,1,0,0,1,0
        \t\t}
        \t\tPolygonVertexIndex: *4 {
        \t\t\ta: 0,1,2,-4
        \t\t}
        \t\tGeometryVersion: 124
        \t}
        \tModel: 200, "Model::Quad", "Mesh" {
        \t\tVersion: 232
        \t\tProperties70:  {
        \t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",10,0,0
        \t\t}
        \t\tShading: T
        \t\tCulling: "CullingOff"
        \t}
        \tMaterial: 300, "Material::Red", "" {
        \t\tShadingModel: "phong"
        \t\tProperties70:  {
        \t\t\tP: "DiffuseColor", "Color", "", "A",1,0,0
        \t\t\tP: "DiffuseFactor", "Number", "", "A",0.5
        \t\t\tP: "SpecularColor", "Color", "", "A",0.25,0.25,0.25
        \t\t\tP: "ShininessExponent", "Number", "", "A",20
        \t\t}
        \t}
        \tAnimationStack: 400, "AnimStack::Take 001", "" {
        \t\tProperties70:  {
        \t\t\tP: "LocalStop", "KTime", "Time", "",46186158000
        \t\t}
        \t}
        }

        ; Object connections
        ;------------------------------------------------------------------
        Connections:  {
        \t;Model::Quad, Model::RootNode
        \tC: "OO",200,0
        \tC: "OO",100,200
        \tC: "OO",300,200
        \tC: "OO",400,0
        }

        """

    @Test func ascii() throws {
        let model = try Self.load(Self.asciiQuad)
        #expect(model.vertexCount == 6)
        // The quad is moved to X = 10, and then turned so that the Z axis is up (Y, in the app).
        Self.expectPositions(model, 0, [10, 0, 0, 11.5, 0, 0, 11.5, 0, -1])
        Self.expectPositions(model, 3, [10, 0, 0, 11.5, 0, -1, 10, 0, -1])
        for v in 0..<6 {
            Self.expectNormal(model, v, 0, 1, 0)
        }
        #expect(model.texCoords == nil)
        #expect(model.parts.count == 1)
        let material = model.parts[0].material
        Self.expectVector(material.diffuseColor, [0.5, 0, 0])
        Self.expectVector(material.specularColor, [0.25, 0.25, 0.25])
        #expect(abs(material.shininess - 20) < Self.tolerance)
    }

    @Test func binary() throws {
        for version in [7400, 7500] {
            // A quad that's split into two triangles, with a different material for each, of which one has a texture.
            let objects = node("Objects").add(
                node("Geometry", Int64(100), "Quad\0\u{1}Geometry", "Mesh").add(
                    node("Vertices", [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0] as [Double]),
                    node("PolygonVertexIndex", [0, 1, -3, 0, 2, -4] as [Int32]),
                    node("LayerElementUV", Int32(0)).add(
                        node("MappingInformationType", "ByPolygonVertex"),
                        node("ReferenceInformationType", "IndexToDirect"),
                        node("UV", [0, 0, 1, 0, 1, 1, 0, 1] as [Double]),
                        node("UVIndex", [0, 1, 2, 0, 2, 3] as [Int32])),
                    node("LayerElementMaterial", Int32(0)).add(
                        node("MappingInformationType", "ByPolygon"),
                        node("ReferenceInformationType", "IndexToDirect"),
                        node("Materials", [1, 0] as [Int32]))),
                node("Model", Int64(200), "Quad\0\u{1}Model", "Mesh").add(node("Version", Int32(232))),
                node("Material", Int64(300), "Red\0\u{1}Material", "").add(properties(
                    node("P", "DiffuseColor", "Color", "", "A", 1.0, 0.0, 0.0))),
                node("Material", Int64(301), "Textured\0\u{1}Material", "").add(properties(
                    node("P", "DiffuseColor", "Color", "", "A", 0.5, 0.5, 0.5))),
                node("Texture", Int64(400), "Image\0\u{1}Texture", "").add(node("RelativeFilename", "missing.png")),
                node("Video", Int64(500), "Image\0\u{1}Video", "Clip").add(node("Content", Self.image)),
                node("AnimationCurve", Int64(600), "\0\u{1}AnimCurve", "").add(node("KeyValueFloat", [1, 2] as [Double])))
            let connections = node("Connections").add(
                node("C", "OO", Int64(200), Int64(0)),
                node("C", "OO", Int64(100), Int64(200)),
                node("C", "OO", Int64(300), Int64(200)),
                node("C", "OO", Int64(301), Int64(200)),
                node("C", "OP", Int64(400), Int64(301), "DiffuseColor"),
                node("C", "OO", Int64(500), Int64(400)))
            let data = try BinaryWriter(version: version).write(
                node("FBXHeaderExtension").add(node("FBXVersion", Int32(version))),
                node("GlobalSettings").add(properties(node("P", "UpAxis", "int", "Integer", "", Int32(1)))),
                objects, connections)
            // The texture is embedded, so no files are requested.
            let resources = MapModelResources([:])
            let model = try FbxModel(data: data, resources: resources)
            #expect(resources.requested.isEmpty)

            #expect(model.vertexCount == 6)
            Self.expectPositions(model, 0, [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1, 0, 0, 1, 0])
            for v in 0..<6 {
                Self.expectNormal(model, v, 0, 0, 1)
            }
            let parts = model.parts
            #expect(parts.count == 2)
            // The textured material comes first, since the first triangle has it.
            Self.expectPart(parts[0], 0, 3)
            #expect(parts[0].material.diffuseTexture == Self.image)
            Self.expectVector(parts[0].material.diffuseColor, [1, 1, 1])
            Self.expectPart(parts[1], 3, 3)
            #expect(parts[1].material.diffuseTexture == nil)
            Self.expectVector(parts[1].material.diffuseColor, [1, 0, 0])
            Self.expectTexCoords(model, [0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1])
        }
    }

    @Test func version6() throws {
        // In version 6, meshes are in their models, and objects are connected by name.
        let fbx = """
            ; FBX 6.1.0 project file
            FBXHeaderExtension:  {
            \tFBXHeaderVersion: 1003
            \tFBXVersion: 6100
            }
            Objects:  {
            \tModel: "Model::Tri", "Mesh" {
            \t\tVersion: 232
            \t\tProperties60:  {
            \t\t\tProperty: "QuaternionInterpolate", "bool", "",0
            \t\t\tProperty: "Lcl Translation", "Lcl Translation", "A+",0.000000,5.000000,0.000000
            \t\t\tProperty: "Lcl Scaling", "Lcl Scaling", "A+",2.000000,2.000000,2.000000
            \t\t}
            \t\tVertices: 0.000000,0.000000,0.000000,1.000000,0.000000,0.000000
            \t\t,0.000000,1.000000,0.000000
            \t\tPolygonVertexIndex: 0,1,-3
            \t\tLayerElementNormal: 0 {
            \t\t\tVersion: 101
            \t\t\tName: ""
            \t\t\tMappingInformationType: "ByVertice"
            \t\t\tReferenceInformationType: "Direct"
            \t\t\tNormals: 0.000000,0.000000,1.000000,0.000000,0.000000,1.000000,
            \t\t\t         0.000000,0.000000,1.000000
            \t\t}
            \t\tLayerElementUV: 0 {
            \t\t\tMappingInformationType: "ByPolygonVertex"
            \t\t\tReferenceInformationType: "IndexToDirect"
            \t\t\tUV: 0,0,1,0,0,1
            \t\t\tUVIndex: 0,1,2
            \t\t}
            \t\tLayerElementTexture: 0 {
            \t\t\tMappingInformationType: "ByPolygon"
            \t\t\tReferenceInformationType: "IndexToDirect"
            \t\t\tBlendMode: "Translucent"
            \t\t\tTextureAlpha: 1
            \t\t\tTextureId: 0
            \t\t}
            \t\tLayerElementMaterial: 0 {
            \t\t\tMappingInformationType: "AllSame"
            \t\t\tReferenceInformationType: "IndexToDirect"
            \t\t\tMaterials: 0
            \t\t}
            \t}
            \tMaterial: "Material::Blue", "" {
            \t\tProperties60:  {
            \t\t\tProperty: "ShadingModel", "KString", "", "Phong"
            \t\t\tProperty: "DiffuseColor", "ColorRGB", "",0.0000,0.0000,1.0000
            \t\t}
            \t}
            \tTexture: "Texture::Image", "TextureVideoClip" {
            \t\tFileName: "C:\\Users\\Someone\\textures\\image.png"
            \t\tRelativeFilename: "textures\\image.png"
            \t}
            \tGlobalSettings:  {
            \t\tVersion: 1000
            \t\tProperties60:  {
            \t\t\tProperty: "UpAxis", "int", "",1
            \t\t}
            \t}
            }
            Connections:  {
            \tConnect: "OO", "Model::Tri", "Model::Scene"
            \tConnect: "OO", "Material::Blue", "Model::Tri"
            \tConnect: "OO", "Texture::Image", "Model::Tri"
            }
            Takes:  {
            \tCurrent: ""
            }

            """
        let resources = ExactPathResources(["textures\\image.png": Self.image])
        var model = try Self.load(fbx, resources)
        #expect(resources.requested == ["textures\\image.png"])
        #expect(model.vertexCount == 3)
        Self.expectPositions(model, 0, [0, 5, 0, 2, 5, 0, 0, 7, 0])
        for v in 0..<3 {
            Self.expectNormal(model, v, 0, 0, 1)
        }
        Self.expectTexCoords(model, [0, 0, 1, 0, 0, 1])
        #expect(model.parts.count == 1)
        Self.expectPart(model.parts[0], 0, 3)
        var material = model.parts[0].material
        #expect(material.diffuseTexture == Self.image)
        Self.expectVector(material.diffuseColor, [1, 1, 1])

        // Without the texture, the model has the color of its material.
        model = try Self.load(fbx, MapModelResources([:]))
        #expect(model.texCoords == nil)
        material = model.parts[0].material
        #expect(material.diffuseTexture == nil)
        Self.expectVector(material.diffuseColor, [0, 0, 1])
    }

    @Test(arguments: [0, 3])
    func transforms(order: Int) throws {
        // A triangle in a model that's rotated (in the given order) in its parent, which has a
        // pre-rotation and a translation; and the same triangle in a model that's rotated about a pivot.
        let fbx = Self.asciiScene("""
            \tModel: 10, "Model::Parent", "Null" {
            \t\tProperties70:  {
            \t\t\tP: "PreRotation", "Vector3D", "Vector", "",0,0,90
            \t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",0,0,5
            \t\t}
            \t}
            \tModel: 20, "Model::Child", "Mesh" {
            \t\tProperties70:  {
            \t\t\tP: "RotationOrder", "enum", "", "",\(order)
            \t\t\tP: "Lcl Rotation", "Lcl Rotation", "", "A",90,90,0
            \t\t}
            \t}
            \tModel: 30, "Model::Pivoted", "Mesh" {
            \t\tProperties70:  {
            \t\t\tP: "RotationPivot", "Vector3D", "Vector", "",1,0,0
            \t\t\tP: "Lcl Rotation", "Lcl Rotation", "", "A",0,0,90
            \t\t\tP: "GeometricTranslation", "Vector3D", "Vector", "",1,0,0
            \t\t}
            \t}

            """ + Self.triangleGeometry(40) + Self.triangleGeometry(41), """
            \tC: "OO",10,0
            \tC: "OO",20,10
            \tC: "OO",30,0
            \tC: "OO",40,20
            \tC: "OO",41,30

            """)
        let model = try Self.load(fbx)
        #expect(model.vertexCount == 6)
        if order == 0 {
            // X, then Y: (1, 0, 0) becomes (0, 0, -1), and (0, 1, 0) becomes (1, 0, 0), before the parent's transform.
            Self.expectPositions(model, 0, [0, 0, 5, 0, 0, 4, 0, 1, 5])
        } else {
            // Y, then X: (1, 0, 0) becomes (0, 1, 0), and (0, 1, 0) becomes (0, 0, 1).
            Self.expectPositions(model, 0, [0, 0, 5, -1, 0, 5, 0, 0, 6])
        }
        // The geometry is moved to the pivot, about which it's rotated.
        Self.expectPositions(model, 3, [1, 0, 0, 1, 1, 0, 0, 0, 0])
    }

    @Test func mirroredTransform() throws {
        let fbx = Self.asciiScene("""
            \tModel: 10, "Model::Mirrored", "Mesh" {
            \t\tProperties70:  {
            \t\t\tP: "Lcl Scaling", "Lcl Scaling", "", "A",-1,1,1
            \t\t}
            \t}
            \tGeometry: 20, "Geometry::Triangle", "Mesh" {
            \t\tVertices: *9 {
            \t\t\ta: 0,0,0,1,0,0,0,1,0
            \t\t}
            \t\tPolygonVertexIndex: *3 {
            \t\t\ta: 0,1,-3
            \t\t}
            \t\tLayerElementNormal: 0 {
            \t\t\tMappingInformationType: "ByPolygonVertex"
            \t\t\tReferenceInformationType: "Direct"
            \t\t\tNormals: *9 {
            \t\t\t\ta: 0,0,1,0,0,1,0,0,1
            \t\t\t}
            \t\t}
            \t}

            """, """
            \tC: "OO",10,0
            \tC: "OO",20,10

            """)
        let model = try Self.load(fbx)
        // The mirrored triangle still faces +Z, so its corners are reversed, to keep it from facing the other way.
        Self.expectPositions(model, 0, [0, 0, 0, 0, 1, 0, -1, 0, 0])
        for v in 0..<3 {
            Self.expectNormal(model, v, 0, 0, 1)
        }
    }

    @Test(arguments: [true, false])
    func skinning(withTransform: Bool) throws {
        // A triangle in a mesh at X = 5, whose first two vertices are moved by a bone that was at the
        // mesh's origin when they were bound, and which is now rotated, and moved to Y = 10.
        let transform = withTransform ? """
            \t\tTransform: *16 {
            \t\t\ta: 1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1
            \t\t}

            """ : ""
        let fbx = Self.asciiScene("""
            \tModel: 10, "Model::Skinned", "Mesh" {
            \t\tProperties70:  {
            \t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",5,0,0
            \t\t}
            \t}
            \tGeometry: 20, "Geometry::Triangle", "Mesh" {
            \t\tVertices: *9 {
            \t\t\ta: 0,0,0,1,0,0,0,1,0
            \t\t}
            \t\tPolygonVertexIndex: *3 {
            \t\t\ta: 0,1,-3
            \t\t}
            \t\tLayerElementNormal: 0 {
            \t\t\tMappingInformationType: "ByPolygonVertex"
            \t\t\tReferenceInformationType: "Direct"
            \t\t\tNormals: *9 {
            \t\t\t\ta: 0,0,1,0,0,1,0,0,1
            \t\t\t}
            \t\t}
            \t}
            \tDeformer: 30, "Deformer::Skin", "Skin" {
            \t\tVersion: 101
            \t\tLink_DeformAcuracy: 50
            \t}
            \tDeformer: 40, "SubDeformer::Bone", "Cluster" {
            \t\tVersion: 100
            \t\tUserData: "", ""
            \t\tIndexes: *2 {
            \t\t\ta: 0,1
            \t\t}
            \t\tWeights: *2 {
            \t\t\ta: 1,0.5
            \t\t}

            """ + transform + """
            \t\tTransformLink: *16 {
            \t\t\ta: 1,0,0,0,0,1,0,0,0,0,1,0,5,0,0,1
            \t\t}
            \t}
            \tModel: 50, "Model::Bone", "LimbNode" {
            \t\tProperties70:  {
            \t\t\tP: "Lcl Translation", "Lcl Translation", "", "A",0,10,0
            \t\t\tP: "Lcl Rotation", "Lcl Rotation", "", "A",0,0,90
            \t\t}
            \t}

            """, """
            \tC: "OO",10,0
            \tC: "OO",50,0
            \tC: "OO",20,10
            \tC: "OO",30,20
            \tC: "OO",40,30
            \tC: "OO",50,40

            """)
        let model = try Self.load(fbx)
        // The first vertex moves with the bone, and so does the second (whose only weight is
        // for the bone, so it counts fully), and the third, without a bone, stays with the mesh.
        Self.expectPositions(model, 0, [0, 10, 0, 0, 11, 0, 5, 1, 0])
        for v in 0..<3 {
            Self.expectNormal(model, v, 0, 0, 1)
        }
    }

    @Test func embeddedTextureInAscii() throws {
        // Embedded files are encoded in Base64, possibly in several strings.
        let encoded = Self.image.base64EncodedString()
        let first = String(encoded.prefix(5))
        let rest = String(encoded.dropFirst(5))
        let fbx = Self.asciiScene("""
            \tModel: 10, "Model::Triangle", "Mesh" {
            \t}
            \tModel: 11, "Model::Hidden", "Mesh" {
            \t\tProperties70:  {
            \t\t\tP: "Visibility", "Visibility", "", "A",0
            \t\t}
            \t}
            \tModel: 12, "Model::Control", "Line" {
            \t}
            \tGeometry: 13, "Geometry::Control", "Line" {
            \t\tPoints: *6 {
            \t\t\ta: 0,0,0,1,1,1
            \t\t}
            \t}
            \tMaterial: 30, "Material::Textured", "" {
            \t}
            \tTexture: 40, "Texture::Image", "" {
            \t\tRelativeFilename: "image.png"
            \t}
            \tVideo: 50, "Video::Image", "Clip" {
            \t\tContent: ,
            \t\t"\(first)",
            \t\t"\(rest)"
            \t}

            """ + Self.triangleGeometry(20), """
            \tC: "OO",10,0
            \tC: "OO",11,0
            \tC: "OO",12,0
            \tC: "OO",20,10
            \tC: "OO",20,11
            \tC: "OO",13,12
            \tC: "OO",30,10
            \tC: "OP",40,30, "DiffuseColor"
            \tC: "OO",50,40

            """)
        let resources = MapModelResources([:])
        let model = try Self.load(fbx, resources)
        // The texture is embedded, so no files are requested.
        #expect(resources.requested.isEmpty)
        // The hidden model and the line aren't shown.
        #expect(model.vertexCount == 3)
        #expect(model.parts[0].material.diffuseTexture == Self.image)
        #expect(model.parts[0].material.diffuseTextureName == "Image")
    }

    @Test func invalidFiles() throws {
        // Files without meshes, such as those with only animations.
        #expect(throws: (any Error).self) {
            try Self.load(Self.asciiScene("""
                \tModel: 10, "Model::Root", "Null" {
                \t}

                """, "\tC: \"OO\",10,0\n"))
        }
        #expect(throws: (any Error).self) { try Self.load("solid cube\nendsolid\n") }
        #expect(throws: (any Error).self) { try Self.load("Objects:  {\n\tModel: 10, \"Model::Unfinished\"") }
        #expect(throws: (any Error).self) {
            try Self.load(Self.asciiScene("""
                \tModel: 10, "Model::Triangle", "Mesh" {
                \t}
                \tGeometry: 20, "Geometry::Triangle", "Mesh" {
                \t\tVertices: *3 {
                \t\t\ta: 0,0,0
                \t\t}
                \t\tPolygonVertexIndex: *3 {
                \t\t\ta: 0,1,-3
                \t\t}
                \t}

                """, "\tC: \"OO\",10,0\n\tC: \"OO\",20,10\n"))
        }

        let data = try BinaryWriter(version: 7400).write(node("Objects").add(node("Geometry", Int64(100), "\0\u{1}Geometry", "Mesh")
            .add(node("Vertices", [0, 0, 0, 1, 0, 0, 0, 1, 0] as [Double]))))
        for length in [20, 40, data.count / 2, data.count - 160] {
            #expect(throws: (any Error).self) {
                try FbxModel(data: data.prefix(length), resources: nil)
            }
        }
    }

    // MARK: - Helpers

    private static func triangleGeometry(_ id: Int) -> String {
        """
        \tGeometry: \(id), "Geometry::Triangle", "Mesh" {
        \t\tVertices: *9 {
        \t\t\ta: 0,0,0,1,0,0,0,1,0
        \t\t}
        \t\tPolygonVertexIndex: *3 {
        \t\t\ta: 0,1,-3
        \t\t}
        \t}

        """
    }

    private static func asciiScene(_ objects: String, _ connections: String) -> String {
        "; FBX 7.4.0 project file\nFBXHeaderExtension:  {\n\tFBXVersion: 7400\n}\n"
            + "Objects:  {\n" + objects + "}\nConnections:  {\n" + connections + "}\n"
    }

    @discardableResult
    private static func load(_ fbx: String, _ resources: ModelResources? = nil) throws -> FbxModel {
        try FbxModel(data: Data(fbx.utf8), resources: resources)
    }

    private static func expectPositions(_ model: FbxModel, _ firstVertex: Int, _ expected: [Float],
                                        sourceLocation: SourceLocation = #_sourceLocation) {
        for i in 0..<expected.count {
            let actual = model.vertices[firstVertex * 3 + i]
            #expect(abs(actual - expected[i]) < tolerance, "Coordinate \(i): \(actual) != \(expected[i])", sourceLocation: sourceLocation)
        }
    }

    private static func expectNormal(_ model: FbxModel, _ vertex: Int, _ x: Float, _ y: Float, _ z: Float,
                                     sourceLocation: SourceLocation = #_sourceLocation) {
        let n = model.normals
        #expect(abs(n[vertex * 3] - x) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(n[vertex * 3 + 1] - y) < tolerance, sourceLocation: sourceLocation)
        #expect(abs(n[vertex * 3 + 2] - z) < tolerance, sourceLocation: sourceLocation)
    }

    private static func expectTexCoords(_ model: FbxModel, _ expected: [Float], sourceLocation: SourceLocation = #_sourceLocation) {
        guard let texCoords = model.texCoords else {
            Issue.record("No texture coordinates", sourceLocation: sourceLocation)
            return
        }
        for i in 0..<expected.count {
            #expect(abs(texCoords[i] - expected[i]) < tolerance, "Coordinate \(i)", sourceLocation: sourceLocation)
        }
    }

    private static func expectVector(_ actual: SIMD3<Float>, _ expected: [Float], sourceLocation: SourceLocation = #_sourceLocation) {
        for i in 0..<3 {
            #expect(abs(actual[i] - expected[i]) < tolerance, "\(actual) != \(expected)", sourceLocation: sourceLocation)
        }
    }

    private static func expectPart(_ part: MeshPart, _ first: Int, _ count: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(part.first == first, sourceLocation: sourceLocation)
        #expect(part.count == count, sourceLocation: sourceLocation)
    }
}

/// Resources that only provide files at exactly the requested paths.
private final class ExactPathResources: ModelResources {
    private let files: [String: Data]
    private(set) var requested: [String] = []

    init(_ files: [String: Data]) {
        self.files = files
    }

    func open(_ path: String) -> Data? {
        requested.append(path)
        return files[path]
    }
}

// MARK: - Binary FBX writer

private final class FbxTestNode {
    let name: String
    let properties: [Any]
    var children: [FbxTestNode] = []

    init(_ name: String, _ properties: [Any]) {
        self.name = name
        self.properties = properties
    }

    @discardableResult
    func add(_ nodes: FbxTestNode...) -> FbxTestNode {
        children.append(contentsOf: nodes)
        return self
    }
}

private func node(_ name: String, _ properties: Any...) -> FbxTestNode {
    FbxTestNode(name, properties)
}

private func properties(_ properties: FbxTestNode...) -> FbxTestNode {
    let node = FbxTestNode("Properties70", [])
    node.children.append(contentsOf: properties)
    return node
}

/// Writes nodes in the binary format, with offsets of 32 bits, or 64 bits from version 7.5.
private final class BinaryWriter {
    private var out: [UInt8] = []
    private let wide: Bool

    init(version: Int) {
        wide = version >= 7500
        out.append(contentsOf: Array("Kaydara FBX Binary  ".utf8) + [0, 0x1a, 0])
        putInt32(Int32(version))
    }

    func write(_ nodes: FbxTestNode...) throws -> Data {
        for node in nodes {
            try writeNode(node)
        }
        out.append(contentsOf: [UInt8](repeating: 0, count: wide ? 25 : 13))
        // The footer, which isn't read.
        out.append(contentsOf: [UInt8](repeating: 0, count: 16))
        putInt32(0)
        putInt32(7400)
        out.append(contentsOf: [UInt8](repeating: 0, count: 120))
        return Data(out)
    }

    private func writeNode(_ node: FbxTestNode) throws {
        let start = out.count
        let name = Array(node.name.utf8)
        putOffset(0)
        putOffset(UInt64(node.properties.count))
        putOffset(0)
        out.append(UInt8(name.count))
        out.append(contentsOf: name)
        let propertiesStart = out.count
        for property in node.properties {
            try writeProperty(property)
        }
        let propertiesLength = out.count - propertiesStart
        if !node.children.isEmpty {
            for child in node.children {
                try writeNode(child)
            }
            out.append(contentsOf: [UInt8](repeating: 0, count: wide ? 25 : 13))
        }
        if wide {
            set64(start, UInt64(out.count))
            set64(start + 16, UInt64(propertiesLength))
        } else {
            set32(start, UInt32(out.count))
            set32(start + 8, UInt32(propertiesLength))
        }
    }

    private func putOffset(_ value: UInt64) {
        if wide {
            putUInt64(value)
        } else {
            putInt32(Int32(truncatingIfNeeded: value))
        }
    }

    private func putInt32(_ value: Int32) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private func putUInt64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }

    private func set32(_ offset: Int, _ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { out.replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    private func set64(_ offset: Int, _ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { out.replaceSubrange(offset..<(offset + 8), with: $0) }
    }

    private func writeProperty(_ property: Any) throws {
        switch property {
        case let value as Int32:
            out.append(UInt8(ascii: "I"))
            putInt32(value)
        case let value as Int64:
            out.append(UInt8(ascii: "L"))
            putUInt64(UInt64(bitPattern: value))
        case let value as Double:
            out.append(UInt8(ascii: "D"))
            putUInt64(value.bitPattern)
        case let value as String:
            let bytes = Array(value.utf8)
            out.append(UInt8(ascii: "S"))
            putInt32(Int32(bytes.count))
            out.append(contentsOf: bytes)
        case let value as Data:
            out.append(UInt8(ascii: "R"))
            putInt32(Int32(value.count))
            out.append(contentsOf: value)
        case let values as [Double]:
            // Arrays of doubles are compressed, and arrays of ints aren't.
            var raw: [UInt8] = []
            for value in values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { raw.append(contentsOf: $0) }
            }
            let compressed = try zlibCompress(raw)
            out.append(UInt8(ascii: "d"))
            putInt32(Int32(values.count))
            putInt32(1)
            putInt32(Int32(compressed.count))
            out.append(contentsOf: compressed)
        case let values as [Int32]:
            out.append(UInt8(ascii: "i"))
            putInt32(Int32(values.count))
            putInt32(0)
            putInt32(Int32(values.count * 4))
            for value in values {
                putInt32(value)
            }
        default:
            throw ModelError("Unsupported property: \(property)")
        }
    }

    /// Compresses data in the zlib format: a header, raw Deflate data, and an Adler-32 checksum.
    private func zlibCompress(_ input: [UInt8]) throws -> [UInt8] {
        let capacity = input.count + 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        let size = compression_encode_buffer(buffer, capacity, input, input.count, nil, COMPRESSION_ZLIB)
        if size == 0 {
            throw ModelError("Unable to compress data.")
        }
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in input {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        let adler = (b << 16) | a
        return [0x78, 0x9c] + Array(UnsafeBufferPointer(start: buffer, count: size))
            + [UInt8(adler >> 24), UInt8((adler >> 16) & 0xff), UInt8((adler >> 8) & 0xff), UInt8(adler & 0xff)]
    }
}
