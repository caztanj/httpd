#if OS == {
    case .WINDOWS;
        #if CPU == {
            case .X64;
                #load "windows_x64.jai";

            case .ARM64;
                #load "windows_arm64.jai";
        }

    case .LINUX;
        #if CPU == {
            case .X64;
                #load "linux_x64.jai";

            case .ARM64;
                #load "linux_arm64.jai";
        }


    case .MACOS;
        #if CPU == {
            case .X64;
                #load "macos_x64.jai";

            case .ARM64;
                #load "macos_arm64.jai";
        }
}
