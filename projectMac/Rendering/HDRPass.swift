import Foundation
import Synchronization
import os

/// Opt-in HDR (extended dynamic range) output. Presets are authored for 0...1, so
/// nothing exceeds SDR white on its own: `ExpandPass` boosts the bright parts of the
/// frame past 1.0 into a half-float, extended-sRGB surface, and macOS gives the display
/// the headroom. Blacks are untouched (the boost is gated on luma). Enabled at launch
/// only, because the pixel format can't change on a live context.
enum HDR {
    /// Fixed for the process lifetime; read by every GL view when it builds its pixel format.
    static let isActive = UserDefaults.standard.bool(forKey: AppSettingsKeys.hdrEnabled)
}

/// The live highlight gain, shared between Settings (main thread) and the render thread.
final class HDRGain: @unchecked Sendable {
    private let bits = Atomic<UInt32>(Float(2.0).bitPattern)
    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Draws a scene texture (or a crop of it) as a fullscreen triangle, boosting highlights.
/// One per GL context: programs and VAOs are created in the context that's current at
/// init, and `draw` must run with that context current.
final class ExpandPass {
    private static let logger = Logger(subsystem: "com.projectmac.app", category: "ExpandPass")

    private static let vertexSource = """
    #version 150
    uniform vec2 uvOffset;
    uniform vec2 uvScale;
    out vec2 uv;
    void main() {
        vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
        uv = uvOffset + p * uvScale;
        gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    }
    """

    // Gain ramps in over the top half of luma, so mid-tones and blacks pass unchanged.
    private static let fragmentSource = """
    #version 150
    uniform sampler2D scene;
    uniform float gain;
    in vec2 uv;
    out vec4 color;
    void main() {
        vec3 c = texture(scene, uv).rgb;
        float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
        color = vec4(c * mix(1.0, gain, smoothstep(0.5, 1.0, luma)), 1.0);
    }
    """

    private var program: GLuint = 0
    private var vao: GLuint = 0
    private var uScene: GLint = 0
    private var uGain: GLint = 0
    private var uOffset: GLint = 0
    private var uScale: GLint = 0

    /// Needs the target GL context current. Nil (and logged) if the shaders don't compile.
    init?() {
        guard let vs = Self.compile(GLenum(GL_VERTEX_SHADER), Self.vertexSource),
              let fs = Self.compile(GLenum(GL_FRAGMENT_SHADER), Self.fragmentSource)
        else { return nil }
        program = glCreateProgram()
        glAttachShader(program, vs)
        glAttachShader(program, fs)
        glLinkProgram(program)
        glDeleteShader(vs)
        glDeleteShader(fs)
        var linked: GLint = 0
        glGetProgramiv(program, GLenum(GL_LINK_STATUS), &linked)
        guard linked == GL_TRUE else {
            Self.logger.error("HDR program failed to link")
            return nil
        }
        uScene = glGetUniformLocation(program, "scene")
        uGain = glGetUniformLocation(program, "gain")
        uOffset = glGetUniformLocation(program, "uvOffset")
        uScale = glGetUniformLocation(program, "uvScale")
        glGenVertexArrays(1, &vao)
    }

    private static func compile(_ type: GLenum, _ source: String) -> GLuint? {
        let shader = glCreateShader(type)
        source.withCString { cString in
            var pointer: UnsafePointer<GLchar>? = cString
            glShaderSource(shader, 1, &pointer, nil)
        }
        glCompileShader(shader)
        var ok: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &ok)
        guard ok == GL_TRUE else {
            var log = [GLchar](repeating: 0, count: 512)
            glGetShaderInfoLog(shader, 512, nil, &log)
            logger.error("HDR shader compile failed: \(String(cString: log), privacy: .public)")
            return nil
        }
        return shader
    }

    /// Draws into the current context's default framebuffer. `uvOffset`/`uvScale` select
    /// the part of the texture to show (normalized), for aspect-fill cropping.
    func draw(texture: GLuint, uvOffset: (Float, Float), uvScale: (Float, Float), gain: Float,
              width: GLint, height: GLint) {
        glBindFramebuffer(GLenum(GL_FRAMEBUFFER), 0)
        glViewport(0, 0, width, height)
        glUseProgram(program)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glUniform1i(uScene, 0)
        glUniform1f(uGain, gain)
        glUniform2f(uOffset, uvOffset.0, uvOffset.1)
        glUniform2f(uScale, uvScale.0, uvScale.1)
        glBindVertexArray(vao)
        glDrawArrays(GLenum(GL_TRIANGLES), 0, 3)
        glBindVertexArray(0)
        glUseProgram(0)
    }
}
