main :: () {
    success, arguments=, is_set, free_arguments := parse_arguments(Arguments);
    if !success exit(.FAILED_TO_PARSE_ARGUMENTS);

    default_logger = context.logger;
    context.logger = logger;

    if !is_set.directory {
        log_error("No directory to serve.");
        exit(.NO_DIRECTORY_TO_SERVE);
    }

    arguments.directory = copy_string(get_absolute_path(arguments.directory));

    error := init(*server, arguments.port);
    if error {
        log_error("Unable to initialize the HTTP server.");
        exit(.HTTP_SERVER_INITIALIZATION_FAILED);
    }

    log("Listening on http://localhost:%", arguments.port);

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

    send_response(*server, response);
}

Arguments :: struct {
    quiet:     bool;
    directory: string;

    port: u16 = 3000;

    debug: bool;
}

Exit_Code :: enum {
    SUCCESS;
    FAILED_TO_PARSE_ARGUMENTS;
    NO_DIRECTORY_TO_SERVE;
    HTTP_SERVER_INITIALIZATION_FAILED;
    HTTP_SERVER_POLL_FAILED;
}

quit := false;

arguments: Arguments;
server:    Http_Server;

default_logger: Logger;

#import "Basic" () (MEMORY_DEBUGGER = DEBUG_MEMORY);
#import "Command_Line";
#import "File";
#import "Http_Server";
