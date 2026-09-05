main :: () {
    set_build_options_dc(.{ do_output = false });

    platform_identifier   := get_platform_identifier();
    absolute_include_path := get_absolute_path(sprint("%/include", platform_identifier));
    output_filename       := join(path_strip_filename(#filepath), platform_identifier, ".jai");

    options: Generate_Bindings_Options;
    options.visitor = visitor;

    array_add(*options.library_search_paths, platform_identifier);
    array_add(*options.include_paths, absolute_include_path);

    if OS == .WINDOWS array_add(*options.extra_clang_arguments, "-DWIN32_LEAN_AND_MEAN");

    if OS == {
        case .WINDOWS;
            array_add(*options.libraries, .{ filename = "crypto" });
            array_add(*options.libraries, .{ filename = "ssl" });

        case .LINUX; #through;
        case .MACOS;
            array_add(*options.libraries, .{ filename = "libcrypto" });
            array_add(*options.libraries, .{ filename = "libssl" });

        case;
            assert(false);
    }

    if OS == {
        case .WINDOWS; options.footer = WINDOWS_FOOTER;
        case .LINUX;   options.footer = LINUX_FOOTER;
        case .MACOS;   options.footer = MACOS_FOOTER;
    }

    array_add(*options.source_files, sprint("%/openssl/ssl.h", absolute_include_path));
    array_add(*options.source_files, sprint("%/openssl/err.h", absolute_include_path));

    success := generate_bindings(options, output_filename);
    if !success exit(1);
}

visitor :: (decl: *Declaration, parent_decl: *Declaration) -> Declaration_Visit_Result {
    if !parent_decl && array_find(DECLARATIONS_TO_OMIT, decl.name) {
        decl.decl_flags |= .OMIT_FROM_OUTPUT;
        return .STOP;
    }

    return .RECURSE;
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

DECLARATIONS_TO_OMIT :: string.[
    "ASN1_TIME_to_tm",
    "BIO_gethostbyname",
    "OPENSSL_gmtime",
    "SSL_get_info_callback",
    "SSL_CTX_sess_get_remove_cb",
];

WINDOWS_FOOTER :: #string JAI
FILE   :: void;
time_t :: s64;
JAI

LINUX_FOOTER :: #string JAI
#import "POSIX";
JAI

MACOS_FOOTER :: #string JAI
#import "POSIX";
JAI

#import "Basic";
#import "Bindings_Generator";
#import "Compiler";
#import "File";
#import "File_Utilities";
#import "String";