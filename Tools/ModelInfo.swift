//
//  ModelInfo.swift
//  Command-line harness support: prints a summary of a loaded model, for checking parsers on macOS.
//

import Foundation

func printModelInfo(_ model: Model, file: String = "") {
    var lines: [String] = []
    lines.append("file: \(file)")
    lines.append("type: \(type(of: model)), orientation: \(model.orientation)")
    lines.append(String(format: "bounds: x [%g, %g] y [%g, %g] z [%g, %g]", model.minX, model.maxX, model.minY, model.maxY, model.minZ, model.maxZ))
    lines.append(String(format: "center: %g %g %g", model.centerMassX, model.centerMassY, model.centerMassZ))
    if let mesh = model as? MeshModel {
        lines.append("vertices: \(mesh.vertexCount), normals: \(mesh.normals.count / 3), indices: \(mesh.indexCount), pointCloud: \(mesh.isPointCloud)")
        lines.append("colors: \(mesh.colors.map { "\($0.count / 4)" } ?? "none"), texCoords: \(mesh.texCoords.map { "\($0.count / 2)" } ?? "none")")
        var problems: [String] = []
        if mesh.normals.count != mesh.vertices.count && !mesh.isPointCloud { problems.append("normal count mismatch") }
        if let c = mesh.colors, c.count != mesh.vertexCount * 4 { problems.append("color count mismatch") }
        if let t = mesh.texCoords, t.count != mesh.vertexCount * 2 { problems.append("texcoord count mismatch") }
        if let idx = mesh.indices {
            if idx.count % 3 != 0 { problems.append("index count not a multiple of 3") }
            if let m = idx.max(), Int(m) >= mesh.vertexCount { problems.append("index out of range: \(m)") }
        } else if mesh.vertexCount % 3 != 0 && !mesh.isPointCloud {
            problems.append("vertex count not a multiple of 3")
        }
        if mesh.vertices.contains(where: { !$0.isFinite }) { problems.append("non-finite vertex") }
        if mesh.normals.contains(where: { !$0.isFinite }) { problems.append("non-finite normal") }
        for part in mesh.parts {
            if part.first < 0 || part.first + part.count > mesh.elementCount { problems.append("part out of range: \(part.first)+\(part.count)") }
        }
        lines.append("parts: \(mesh.parts.count)")
        for (i, part) in mesh.parts.prefix(12).enumerated() {
            let m = part.material
            lines.append(String(format: "  [%d] '%@' first %d count %d diffuse (%.2f %.2f %.2f) opacity %.2f shininess %.1f lighting %d alpha %@ texture %@",
                                i, m.name, part.first, part.count, m.diffuseColor.x, m.diffuseColor.y, m.diffuseColor.z, m.opacity, m.shininess,
                                m.lighting.rawValue, "\(m.alphaMode)", m.diffuseTexture.map { "\($0.count) bytes (\(m.diffuseTextureName ?? ""))" } ?? "none"))
        }
        if mesh.parts.count > 12 { lines.append("  ...") }
        lines.append(problems.isEmpty ? "OK" : "PROBLEMS: " + problems.joined(separator: ", "))
    }
    print(lines.joined(separator: "\n"))
}
