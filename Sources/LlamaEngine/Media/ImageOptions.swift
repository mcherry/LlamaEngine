import Foundation

/// The sampling algorithm Easy Diffusion uses. Raw values are the exact `sampler_name`
/// strings the server expects; `label` is the human-facing name shown in a picker.
public enum ImageSampler: String, CaseIterable, Sendable, Identifiable {
    case eulerA = "euler_a"
    case euler
    case dpmpp2m = "dpmpp_2m"
    case dpmpp2mSDE = "dpmpp_2m_sde"
    case dpmppSDE = "dpmpp_sde"
    case dpmpp2sA = "dpmpp_2s_a"
    case dpm2
    case dpm2A = "dpm2_a"
    case heun
    case lms
    case ddim
    case plms
    case ddpm
    case deis
    case unipc = "unipc_snr"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .eulerA: return "Euler Ancestral"
        case .euler: return "Euler"
        case .dpmpp2m: return "DPM++ 2M"
        case .dpmpp2mSDE: return "DPM++ 2M SDE"
        case .dpmppSDE: return "DPM++ SDE"
        case .dpmpp2sA: return "DPM++ 2S Ancestral"
        case .dpm2: return "DPM2"
        case .dpm2A: return "DPM2 Ancestral"
        case .heun: return "Heun"
        case .lms: return "LMS"
        case .ddim: return "DDIM"
        case .plms: return "PLMS"
        case .ddpm: return "DDPM"
        case .deis: return "DEIS"
        case .unipc: return "UniPC"
        }
    }
}

/// A post-generation upscaler Easy Diffusion can apply. Raw values are the exact
/// `use_upscale` strings the server expects; empty means "no upscaling".
public enum ImageUpscaler: String, CaseIterable, Sendable, Identifiable {
    case none = ""
    case realEsrgan4x = "RealESRGAN_x4plus"
    case realEsrgan4xAnime = "RealESRGAN_x4plus_anime_6B"
    case latent = "latent_upscaler"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "None"
        case .realEsrgan4x: return "RealESRGAN x4 (photo)"
        case .realEsrgan4xAnime: return "RealESRGAN x4 (anime)"
        case .latent: return "Latent upscaler"
        }
    }
}

/// A face-restoration model Easy Diffusion can apply after generation. Raw values are the
/// exact `use_face_correction` strings the server expects; empty means "none".
public enum FaceCorrection: String, CaseIterable, Sendable, Identifiable {
    case none = ""
    case gfpgan = "GFPGANv1.4"
    case codeformer = "CodeFormer"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .none: return "None"
        case .gfpgan: return "GFPGAN"
        case .codeformer: return "CodeFormer"
        }
    }
}
