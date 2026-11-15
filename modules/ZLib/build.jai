main :: () {
    set_build_options_dc(.{ do_output = false });

    platform_identifier := get_platform_identifier();

    if file_exists(platform_identifier) delete_directory(platform_identifier);
    make_directory_if_it_does_not_exist(platform_identifier);

    if file_exists(BUILD_DIRECTORY) delete_directory(BUILD_DIRECTORY);
    make_directory_if_it_does_not_exist(BUILD_DIRECTORY);

    absolute_platform_directory := get_absolute_path(platform_identifier);

    set_working_directory(join(path_strip_filename(#filepath), BUILD_DIRECTORY, separator = "/"));

    configure_command: [..] string;

    array_add(
        *configure_command,
        "cmake",
        "-G", "Ninja",
        sprint("-DCMAKE_INSTALL_PREFIX=%", absolute_platform_directory),
        "-DCMAKE_BUILD_TYPE=Release",
    );

    if OS == .WINDOWS array_add(*configure_command, "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded");

    array_add(*configure_command, "..");

    result := run_command(..configure_command);
    if result.exit_code != 0 {
        log_error("Error: Failed to run the cmake configure command.");
        exit(1);
    }

    result = run_command("ninja");
    if result.exit_code != 0 {
        log_error("Error: Failed to run the ninja command.");
        exit(1);
    }

    result = run_command("cmake", "--install", ".");
    if result.exit_code != 0 {
        log_error("Error: Failed to run the cmake install command.");
        exit(1);
    }

    set_working_directory(path_strip_filename(#filepath));

    if OS == {
        case .WINDOWS;
            source_static      := join(platform_identifier, "lib", "zs.lib", separator = "/");
            destination_static := join(platform_identifier, "zlib.lib", separator = "/");

            source_dll      := join(platform_identifier, "bin", "z.dll", separator = "/");
            destination_dll := join(platform_identifier, "zlib.dll", separator = "/");

            atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(source_static, destination_static);
            atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(source_dll, destination_dll);

        case .LINUX;
            source_static      := join(platform_identifier, "lib", "libz.a", separator = "/");
            destination_static := join(platform_identifier, "libz.a",        separator = "/");

            source_so      := join(platform_identifier, "lib", "libz.so", separator = "/");
            destination_so := join(platform_identifier, "libz.so",        separator = "/");

            atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(source_static, destination_static);
            atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(source_so, destination_so);

        case .MACOS;
            source_static      := join(platform_identifier, "lib", "libz.a", separator = "/");
            destination_static := join(platform_identifier, "libz.a",        separator = "/");

            source_dylib      := join(platform_identifier, "lib", "libz.dylib", separator = "/");
            destination_dylib := join(platform_identifier, "libz.dylib",        separator = "/");

            atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(source_static, destination_static);
            atomic_file_replace_or_just_rename_if_destination_file_does_not_exist(source_dylib, destination_dylib);
    }
}

get_platform_identifier :: () -> string {
    operating_system: string;
    architecture:     string;

    if OS == {
        case .WINDOWS; operating_system = "windows";
        case .LINUX;   operating_system = "linux";
        case .MACOS;   operating_system = "macos";
        case;          assert(false, "Unsupported operating system.");
    }

    if CPU == {
        case .X64;   architecture = "x64";
        case .ARM64; architecture = "arm64";
        case;        assert(false, "Unsupported architecture.");
    }

    return sprint("%_%", operating_system, architecture);
}

#run main();

BUILD_DIRECTORY :: "zlib-1.3.2/build";

#import "Basic";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "Process";
#import "String";
