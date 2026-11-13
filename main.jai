main :: () {
    success, arguments=, is_set, free_arguments := parse_arguments(Arguments);
    if !success exit(.FAILED_TO_PARSE_ARGUMENTS);

    default_logger = context.logger;
    context.logger = logger;

    if !is_set.directory {
        log_error("No directory to serve.");
        exit(.NO_DIRECTORY_TO_SERVE);
    }

    if is_set.certificate_file && is_set.private_key_file {
        arguments.tls = true;
    }

    if arguments.tls || is_set.certificate_file || is_set.private_key_file {
        if !is_set.certificate_file || !is_set.private_key_file {
            log_error("Both certificate_file and private_key_file must be specified for TLS.");
            exit(.MISSING_TLS_ARGUMENTS);
        }
    }

    if !is_set.port {
        arguments.port = ifx arguments.tls then cast(u16) 443 else cast(u16) 80;
    }

    #if OS == .LINUX || OS == .MACOS {
        if !is_set.threads {
            arguments.threads = max(1, get_number_of_processors(.ALL_LOGICAL));
        } else if arguments.threads < 1 {
            log_error("Number of threads must be at least 1.");
            exit(.INVALID_THREAD_COUNT);
        }

        thread_count := arguments.threads;
    } else {
        thread_count := 1;
    }

    absolute_directory, directory_ok := get_absolute_path(arguments.directory);
    if !directory_ok {
        log_error("Invalid directory to serve.");
        exit(.NO_DIRECTORY_TO_SERVE);
    }

    arguments.directory = copy_string(absolute_directory);

    servers = NewArray(thread_count, Http_Server);

    for * servers {
        error := init(it, arguments.port, arguments.address, arguments.tls, arguments.certificate_file, arguments.private_key_file, thread_count);
        if error {
            log_error("Unable to initialize the HTTP server.");
            exit(.HTTP_SERVER_INITIALIZATION_FAILED);
        }
    }

    scheme := ifx arguments.tls then "https" else "http";
    if contains(arguments.address, ":") {
        log("Listening on %://[%]:%", scheme, arguments.address, arguments.port);
    } else {
        log("Listening on %://%:%", scheme, arguments.address, arguments.port);
    }

    #if OS == .LINUX || OS == .MACOS {
        threads: [] Thread;
        if thread_count > 1 {
            threads = NewArray(thread_count - 1, Thread);

            for * threads {
                success := thread_init(it, worker_thread);
                if !success {
                    log_error("Unable to initialize worker thread.");
                    exit(.HTTP_SERVER_INITIALIZATION_FAILED);
                }

                it.data = *servers[it_index + 1];
                thread_start(it);
            }
        }
    }

    event_loop(*servers[0]);

    #if OS == .LINUX || OS == .MACOS {
        for * threads {
            thread_is_done(it, -1);
            thread_deinit(it);
        }

        array_free(threads);
    }

    for * servers shutdown(it);
    array_free(servers);

    free(arguments.directory);
    array_free(free_arguments);

    #if DEBUG report_memory_leaks();
}

#if OS == .LINUX || OS == .MACOS {
    worker_thread :: (thread: *Thread) -> s64 {
        server := cast(*Http_Server) thread.data;
        event_loop(server);
        return 0;
    }
}

event_loop :: (server: *Http_Server) {
    while !quit {
        push_allocator(temp);

        error, events := http_server_poll(server);
        if error {
            log_error("Failed to poll the HTTP server.");
            exit(.HTTP_SERVER_POLL_FAILED);
        }

        for events handle_event(server, it);

        reset_temporary_storage();
    }
}

logger :: (message: string, data: *void, info: Log_Info) {
    if arguments.quiet return;
    default_logger(message, data, info);
}

exit :: (code: Exit_Code) {
    #if DEBUG report_memory_leaks();

    exit(cast(s32) code);
}

handle_event :: (server: *Http_Server, event: Http_Event) {
    if event.type != .Http_Request return;

    request := event.http_request;

    if !arguments.quiet {
        print_http_request(*request);
    }

    #if DEBUG {
        if request.uri == "/stop" {
            quit = true;
            for * servers wake_up_event_loop(it);
        }
    }

    response: Http_Response;

    if request.method == .GET {
        response = static_file(request, arguments.directory, directory_is_absolute = true);
    } else {
        response = bad_request(request);
    }

    set_header(*response.headers, "X-Content-Type-Options", "nosniff");
    set_header(*response.headers, "Cross-Origin-Resource-Policy", "same-origin");
    set_header(*response.headers, "X-Frame-Options", "DENY");
    set_header(*response.headers, "Referrer-Policy", "strict-origin-when-cross-origin");
    set_header(*response.headers, "Content-Security-Policy", "script-src 'self'");

    send_response(server, response);
}

Arguments :: struct {
    quiet:     bool;
    directory: string;

    address: string = "127.0.0.1";
    port:    u16    = 80;

    tls:              bool;
    certificate_file: string;
    private_key_file: string;

    #if OS == .LINUX || OS == .MACOS {
        threads: int;
    }
}

Exit_Code :: enum {
    SUCCESS;
    FAILED_TO_PARSE_ARGUMENTS;
    NO_DIRECTORY_TO_SERVE;
    MISSING_TLS_ARGUMENTS;
    INVALID_THREAD_COUNT;
    HTTP_SERVER_INITIALIZATION_FAILED;
    HTTP_SERVER_POLL_FAILED;
}

quit := false;

arguments: Arguments;
servers:   [] Http_Server;

default_logger: Logger;

DEBUG :: false;

#import "Basic" () (MEMORY_DEBUGGER = DEBUG);
#import "Command_Line";
#import "File";
#import "Http_Server";
#import "String";

#if OS == .LINUX || OS == .MACOS {
    #import "System";
    #import "Thread";
}
