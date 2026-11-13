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

    arguments.directory = copy_string(get_absolute_path(arguments.directory));

    error := init(*server, arguments.port, arguments.address, arguments.tls, arguments.certificate_file, arguments.private_key_file);
    if error {
        log_error("Unable to initialize the HTTP server.");
        exit(.HTTP_SERVER_INITIALIZATION_FAILED);
    }

    scheme := ifx arguments.tls then "https" else "http";
    if contains(arguments.address, ":") {
        log("Listening on %://[%]:%", scheme, arguments.address, arguments.port);
    } else {
        log("Listening on %://%:%", scheme, arguments.address, arguments.port);
    }

    while !quit {
        push_allocator(temp);

        error, events := http_server_poll(*server);
        if error {
            log_error("Failed to poll the HTTP server.");
            exit(.HTTP_SERVER_POLL_FAILED);
        }

        for events handle_event(it);

        reset_temporary_storage();
    }

    shutdown(*server);

    free(arguments.directory);
    array_free(free_arguments);

    #if DEBUG_MEMORY report_memory_leaks();
}

logger :: (message: string, data: *void, info: Log_Info) {
    if arguments.quiet return;
    default_logger(message, data, info);
}

exit :: (code: Exit_Code) {
    #if DEBUG_MEMORY report_memory_leaks();

    exit(cast(s32) code);
}

handle_event :: (event: Http_Event) {
    if event.type != .Http_Request return;

    request := event.http_request;

    if !arguments.quiet {
        print_http_request(*request);
    }

    if arguments.debug && request.uri == "/stop" {
        quit = true;
    }

    response: Http_Response;

    if request.method == .GET {
        response = static_file(request, arguments.directory);

        if response.status == .NOT_FOUND {
            request.uri = tprint("%/index.html", request.uri);
            response    = static_file(request, arguments.directory);
        }
    } else {
        response = bad_request(request);
    }

    set_header(*response.headers, "X-Content-Type-Options", "nosniff");
    set_header(*response.headers, "Cross-Origin-Resource-Policy", "same-origin");
    set_header(*response.headers, "X-Frame-Options", "DENY");
    set_header(*response.headers, "Referrer-Policy", "strict-origin-when-cross-origin");
    set_header(*response.headers, "Content-Security-Policy", "script-src 'self'");

    send_response(*server, response);
}

Arguments :: struct {
    quiet:     bool;
    directory: string;

    address: string = "127.0.0.1";
    port:    u16    = 80;

    tls:              bool;
    certificate_file: string;
    private_key_file: string;

    debug: bool;
}

Exit_Code :: enum {
    SUCCESS;
    FAILED_TO_PARSE_ARGUMENTS;
    NO_DIRECTORY_TO_SERVE;
    MISSING_TLS_ARGUMENTS;
    HTTP_SERVER_INITIALIZATION_FAILED;
    HTTP_SERVER_POLL_FAILED;
}

quit := false;

arguments: Arguments;
server:    Http_Server;

default_logger: Logger;

DEBUG_MEMORY :: false;

#import "Basic" () (MEMORY_DEBUGGER = DEBUG_MEMORY);
#import "Command_Line";
#import "File";
#import "Http_Server";
#import "String";
