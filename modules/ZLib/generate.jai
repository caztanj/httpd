main :: () {
    set_build_options_dc(.{ do_output = false });

    args := get_build_options().compile_time_command_line;

    target_arm64 := array_find(args, "arm64");

    target_cpu := ifx target_arm64 CPU.ARM64 else CPU;

    platform_identifier   := get_platform_identifier(target_cpu);
    absolute_include_path := get_absolute_path(sprint("%/include", platform_identifier));
    output_filename       := join(path_strip_filename(#filepath), platform_identifier, ".jai");

    options: Generate_Bindings_Options;
    options.log_stripped_declarations = false;

    array_add(*options.library_search_paths, platform_identifier);
    array_add(*options.include_paths, absolute_include_path);

    if OS == {
        case .WINDOWS;
            array_add(*options.libraries, .{ filename = "zlib" });

        case .LINUX; #through;
        case .MACOS;
            array_add(*options.libraries, .{ filename = "libz" });

        case;
            assert(false);
    }

    array_add(*options.source_files, sprint("%/zlib.h", absolute_include_path));

    error := !generate_bindings(options, output_filename);
    if error exit(1);
}

get_platform_identifier :: (cpu := CPU) -> string {
    operating_system: string;
    architecture:     string;

    if OS == {
        case .WINDOWS; operating_system = "windows";
        case .LINUX;   operating_system = "linux";
        case .MACOS;   operating_system = "macos";
        case;          assert(false);
    }

    if cpu == {
        case .X64;   architecture = "x64";
        case .ARM64; architecture = "arm64";
        case;        assert(false);
    }

    return sprint("%_%", operating_system, architecture);
}

#run main();

#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";
