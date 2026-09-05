build :: () {
    set_build_options_dc(.{ do_output = false });

    arguments := get_build_options().compile_time_command_line;

    plugins: [..] *Metaprogram_Plugin;
    intercept_flags: Intercept_Flags;

    success, plugins_to_create, remaining_arguments := parse_plugin_arguments(arguments);
    if !success exit(1);

    target_x64   := array_find(remaining_arguments, "x64");
    target_arm64 := array_find(remaining_arguments, "arm64");
    release      := array_find(remaining_arguments, "release");

    cpu_target := CPU;
    os_target  := OS;

    if target_x64 {
        cpu_target = .X64;
    }

    if target_arm64 {
        cpu_target = .ARM64;
    }

    w := compiler_create_workspace("httpd");
    options := get_build_options(w);
    copy_commonly_propagated_fields(get_build_options(), *options);

    options.cpu_target = cpu_target;
    options.os_target  = os_target;
    options.output_executable_name = "httpd";

    if cpu_target == .ARM64 && os_target == .LINUX {
        options.backend = .LLVM;
        options.llvm_options.target_system_triple = "aarch64-linux-gnu";
        options.use_custom_link_command = true;
    }

    options.output_path = ifx release "build_release" else "build_debug";

    if release set_optimization(*options, .OPTIMIZED);

    set_build_options(options, w);

    success = init_plugins(plugins_to_create, *plugins, w);
    if !success exit(1);

    make_directory_if_it_does_not_exist(options.output_path);

    for plugins if it.before_intercept it.before_intercept(it, *intercept_flags);

    compiler_begin_intercept(w, intercept_flags);

    for plugins if it.add_source it.add_source(it);

    if release add_build_string("DEBUG_MEMORY :: false;", w);
    else       add_build_string("DEBUG_MEMORY :: true;", w);

    add_build_file("main.jai", w);

    while true {
        message := compiler_wait_for_message();

        for plugins if it.message it.message(it, message);

        if message.kind == {
            case .PHASE;
                phase := cast(*Message_Phase) message;
                if phase.phase == .READY_FOR_CUSTOM_LINK_COMMAND {
                    phase.executable_name = run_linux_cross_link_command(w, phase);
                    compiler_custom_link_command_is_complete(w);
                }

            case .ERROR;
                exit(1);

            case .COMPLETE;
                break;
        }
    }

    compiler_end_intercept(w);

    for plugins if it.finish   it.finish(it);
    for plugins if it.shutdown it.shutdown(it);
}

run_linux_cross_link_command :: (w: Workspace, m: *Message_Phase) -> string {
    options := get_build_options(w);
    output_filename := tprint("%/%", ifx options.output_path else ".", options.output_executable_name);

    arguments: [..] string;

    array_add(*arguments, "aarch64-linux-gnu-gcc");
    array_add(*arguments, "-no-pie");

    for m.compiler_generated_object_files array_add(*arguments, it);
    // for m.support_object_files            array_add(*arguments, it);

    for m.user_libraries {
        library := it;

        extension := path_extension(library);
        if extension == "" library = tprint("%.a", library);

        array_add(*arguments, library);
    }

    for m.system_libraries {
        library := it;

        path, basename, extension, filename := path_decomp(library);

        if extension == "dll" {
            if starts_with(basename, "lib") {
                advance(*basename, 3);
                library = tprint("-l%", basename);
            } else {
                library = tprint("%.a", basename);
            }
        }

        array_add(*arguments, library);
    }

    array_add(*arguments, "-o", output_filename);

    log("Running linker: %", get_quoted_command_string(arguments));

    result := run_command(..arguments);
    if result.exit_code != 0 {
        details: string;

        if result.type == {
            case .FAILED_TO_LAUNCH;
                details = "Could not launch linker.";

            case .SIGNALED;
                details = tprint("Linker caught signal %.", result.signal);

            case;
                details = tprint("Linker exit code %.", result.exit_code);
        }

        log_error("Linking failed. %", details);
        compiler_set_workspace_status(.FAILED, w);
    }

    return output_filename;
}

#run build();

#import "Basic";
#import "Compiler";
#import "File";
#import "Metaprogram_Plugins";
#import "Process";
#import "String";