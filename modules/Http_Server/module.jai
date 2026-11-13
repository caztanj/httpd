#module_parameters () (MAX_REQUEST_SIZE := 65536, MAX_WEB_SOCKET_MESSAGE_SIZE := 16_777_216, MAX_SEND_BUFFER_SIZE := 16_777_216, MAX_CLIENTS := 0);

// @Note: If MAX_SEND_BUFFER_SIZE is set to 0 the max value will be infinite.

// @Note: If MAX_CLIENTS is set to 0 the max value will be:
//        Windows: Infinite
//        macOS:   (RLIMIT_NOFILE - 32) / 2
//        Linux:   (RLIMIT_NOFILE - 32) / 2

get_header :: (headers: [] Http_Header, key: string) -> error: bool, string {
    for headers {
        if equal_nocase(it.key, key) return false, it.value;
    }

    return true, "";
}

set_header :: (headers: *[..] Http_Header, key: string, value: string) {
    if key.count == 0 return;

    for key {
        if !HEADER_KEY_ALLOWED_CHARS[it] return;
    }

    for value {
        if (it < 0x20 && it != #char "\t") || it == 0x7F return;
    }

    push_allocator(temp);

    for * headers.* {
        if equal_nocase(it.key, key) {
            it.value = value;
            return;
        }
    }

    header := Http_Header.{ key = key, value = value };

    array_add(headers, header);
}

static_file :: (request: Http_Request, directory: string, directory_is_absolute := false) -> Http_Response {
    push_allocator(temp);

    decoded_uri := percent_decode(request.uri);
    if contains(decoded_uri, "\0") return bad_request(request);

    resolve_path :: (path: string) -> string, success: bool {
        #if OS == .LINUX || OS == .MACOS {
            buffer: [4096] u8;
            result := POSIX.realpath(temp_c_string(path), buffer.data);
            if result == null return "", false;

            return copy_temporary_string(to_string(buffer.data)), true;
        } else {
            absolute_path, success := get_absolute_path(path);
            return absolute_path, success;
        }
    }

    absolute_directory := directory;
    if !directory_is_absolute {
        success: bool;
        absolute_directory, success = resolve_path(directory);
        if !success return internal_server_error(request);
    }

    path := join(absolute_directory, "/", decoded_uri);

    path_is_directory, success := is_directory(path);
    if !success return not_found(request);

    if path_is_directory {
        index_path := tprint("%/index.html", path);
        if file_exists(index_path) path = index_path;
        else                       return not_found(request);
    }

    absolute_path: string;
    absolute_path, success = resolve_path(path);
    if !success return not_found(request);

    is_inside :: (path: string, directory: string) -> bool {
        if !starts_with(path, directory)                           return false;
        if path.count == directory.count                           return true;
        if ends_with(directory, "/") || ends_with(directory, "\\") return true;

        return path[directory.count] == "/" || path[directory.count] == "\\";
    }

    if !is_inside(absolute_path, absolute_directory) return not_found(request);

    error, range := get_header(request.headers, "Range");
    if !error return serve_static_file_range(request, absolute_path);

    return serve_entire_static_file(request, absolute_path);
}

text :: (request: Http_Request, text: string, content_type := "text/plain") -> Http_Response {
    response: Http_Response;
    response.client_id = request.client_id;

    response.status = .OK;
    response.body   = text;

    set_header(*response.headers, "Content-Type", content_type);
    set_header(*response.headers, "Content-Length", tprint("%", text.count));

    return response;
}

html :: (request: Http_Request, html: string) -> Http_Response {
    return text(request, html, "text/html");
}

css :: (request: Http_Request, css: string) -> Http_Response {
    return text(request, css, "text/css");
}

js :: (request: Http_Request, js: string) -> Http_Response {
    return text(request, js, "application/js");
}

json :: (request: Http_Request, json: string) -> Http_Response {
    return text(request, json, "application/json");
}

not_found :: (request: Http_Request) -> Http_Response {
    response: Http_Response;
    response.client_id = request.client_id;

    response.status = .NOT_FOUND;

    set_header(*response.headers, "Content-Length", "0");

    return response;
}

bad_request :: (request: Http_Request) -> Http_Response {
    response: Http_Response;
    response.client_id = request.client_id;

    response.status = .BAD_REQUEST;

    set_header(*response.headers, "Content-Length", "0");

    return response;
}

internal_server_error :: (request: Http_Request) -> Http_Response {
    response: Http_Response;
    response.client_id = request.client_id;

    response.status = .INTERNAL_SERVER_ERROR;

    set_header(*response.headers, "Content-Length", "0");

    return response;
}

print_http_request :: (request: *Http_Request) {
    b: String_Builder;
    b.allocator = temp;

    print_to_builder(*b, "%", request.method);

    print_to_builder(*b, " % HTTP/1.1\n", request.uri);

    for request.headers {
        print_to_builder(*b, "%: %\n", it.key, it.value);
    }

    if request.body.count != 0 {
        for request.body {
            if (it < 0x20 && it != #char "\n" && it != #char "\t") || it == 0x7F {
                append(*b, ".");
            } else {
                append(*b, it);
            }
        }

        append(*b, "\n");
    }

    print("%\n", builder_to_string(*b,, temp));
}

print_http_response :: (response: Http_Response) {
    b: String_Builder;
    b.allocator = temp;

    print_to_builder(*b, "HTTP/1.1 %\r\n", http_response_status_to_string(response.status));

    for response.headers {
        print_to_builder(*b, "%: %\r\n", it.key, it.value);
    }

    print("%\n", builder_to_string(*b,, temp));
}

percent_decode :: (s: string) -> string {
    b: String_Builder;
    b.allocator = temp;

    t     := s.data;
    max_t := t + s.count;

    start := t;

    while t < max_t {
        if t.* == "%" && (t + 2) < max_t {
            hex_char_to_int :: (c: u8) -> error: bool, int {
                if c >= "0" && c <= "9" return false, c - "0";
                if c >= "a" && c <= "f" return false, c - "a" + 10;
                if c >= "A" && c <= "F" return false, c - "A" + 10;

                return true, 0;
            }

            error_1, value_1 := hex_char_to_int((t + 1).*);
            error_2, value_2 := hex_char_to_int((t + 2).*);

            if !error_1 && !error_2 {
                if t > start append(*b, string.{ data = start, count = t - start });

                append(*b, (value_1 * 16 + value_2).(u8));

                t += 3;
                start = t;

                continue;
            }
        }

        t += 1;
    }

    if start < max_t {
        append(*b, string.{ data = start, count = max_t - start });
    }

    return builder_to_string(*b);
}

html_escape :: (s: string) -> string {
    b: String_Builder;
    b.allocator = temp;

    t     := s.data;
    max_t := t + s.count;

    start := t;

    while t < max_t {
        if t.* == {
            case "&";
                append(*b, string.{ data = start, count = t - start });
                append(*b, "&amp;");
                start = t + 1;
            case "<";
                append(*b, string.{ data = start, count = t - start });
                append(*b, "&lt;");
                start = t + 1;
            case ">";
                append(*b, string.{ data = start, count = t - start });
                append(*b, "&gt;");
                start = t + 1;
            case "\"";
                append(*b, string.{ data = start, count = t - start });
                append(*b, "&quot;");
                start = t + 1;
            case "'";
                append(*b, string.{ data = start, count = t - start });
                append(*b, "&#39;");
                start = t + 1;
        }

        t += 1;
    }

    if start < max_t {
        append(*b, string.{ data = start, count = max_t - start });
    }

    return builder_to_string(*b);
}

wake_up_event_loop :: (server: *Http_Server) {
    addr: Socket.sockaddr_in;
    addr.sin_family = Socket.AF_INET;
    addr.sin_port = Socket.htons(server.wake_up_port);

    #if OS == .WINDOWS {
        addr.sin_addr.S_un.S_addr = Socket.htonl(0x7F000001);
    } else {
        addr.sin_addr.s_addr = Socket.htonl(0x7F000001);
    }

    dummy: u8 = 1;
    Socket.sendto(server.wake_up_socket, cast(*u8)*dummy, 1, 0, cast(*Socket.sockaddr)*addr, size_of(type_of(addr)));
}

send_response :: (server: *Http_Server, response: Http_Response) {
    push_allocator(context.default_allocator);

    client := find_client(server, response.client_id);
    if client == null return;

    status_string := http_response_status_to_string(response.status);

    total_size := "HTTP/1.1 ".count + status_string.count + "\r\n".count;

    for response.headers {
        total_size += it.key.count + ": ".count + it.value.count + "\r\n".count;
    }

    total_size += "\r\n".count + response.body.count;

    array_reserve(*client.send_buffer, client.send_buffer.count + total_size);

    append_to_send_buffer :: (send_buffer: *[..] u8, s: string) {
        if s.count == 0 return;
        memcpy(send_buffer.data + send_buffer.count, s.data, s.count);
        send_buffer.count += s.count;
    }

    append_to_send_buffer(*client.send_buffer, "HTTP/1.1 ");
    append_to_send_buffer(*client.send_buffer, status_string);
    append_to_send_buffer(*client.send_buffer, "\r\n");

    for response.headers {
        append_to_send_buffer(*client.send_buffer, it.key);
        append_to_send_buffer(*client.send_buffer, ": ");
        append_to_send_buffer(*client.send_buffer, it.value);
        append_to_send_buffer(*client.send_buffer, "\r\n");
    }

    append_to_send_buffer(*client.send_buffer, "\r\n");
    append_to_send_buffer(*client.send_buffer, response.body);

    if response.file.handle {
        if client.send_file.handle file_close(*client.send_file);

        client.send_file        = response.file;
        client.send_file_offset = response.file_offset;
        client.send_file_end    = ifx response.file_size >= 0 then response.file_offset + response.file_size else file_length(client.send_file);
    }

    send_to_client(server, response.client_id);
}

shutdown :: (server: *Http_Server) {
    for * server.clients {
        close(server, it, now = true);
    }

    deinit(*server.clients);

    array_reset(*server.clients_to_close_in_next_iteration);
    array_reset(*server.clients_with_pending_reads);

    if server.tls {
        LibreSSL.SSL_CTX_free(server.ssl_ctx);
    }

    #if OS == .MACOS {
        array_reset(*server.kqueue_changes);
    }

    #if OS == .WINDOWS {
        array_reset(*server.wsapollfds);
    }
}

add_timer :: (server: *Http_Server, milliseconds: int) -> u64 {
    timer: Http_Timer;
    timer.id      = server.next_timer_id;
    timer.timeout = current_time_monotonic() + milliseconds_to_apollo(milliseconds);

    server.next_timer_id += 1;

    array_add(*server.timers, timer);

    return timer.id;
}

add_timer :: (server: *Http_Server, time: Apollo_Time) -> u64 {
    timer: Http_Timer;
    timer.id      = server.next_timer_id;
    timer.timeout = time;

    server.next_timer_id += 1;

    array_add(*server.timers, timer);

    return timer.id;
}

remove_timer :: (server: *Http_Server, id: u64) {
    for server.timers {
        if it.id == id {
            remove it;
            return;
        }
    }
}

Http_Request :: struct {
    client_id: Socket.Socket;

    uri:    string;
    method: Http_Method;

    headers: [..] Http_Header;
    headers.allocator = temp;

    body: string;
}

Http_Response :: struct {
    client_id: Socket.Socket;

    status: Http_Response_Status;

    headers: [..] Http_Header;
    headers.allocator = temp;

    body: string;

    file:        File;
    file_offset: int;
    file_size:   int = -1;
}

Http_Method :: enum {
    GET;
    HEAD;
    POST;
    PUT;
    DELETE;
    CONNECT;
    OPTIONS;
    TRACE;
    PATCH;
}

Http_Header :: struct {
    key:   string;
    value: string;
}

Http_Event_Type :: enum {
    Http_Request;
    Web_Socket_Message;
    Client_Closed;
    Timer;
}

Http_Event :: struct {
    type: Http_Event_Type;

    union {
        http_request:       Http_Request;
        web_socket_message: Web_Socket_Message;
        client_closed:      Socket.Socket;
        timer:              u64;
    };
}

Http_Timer :: struct {
    id:      u64;
    timeout: Apollo_Time;
}

#scope_module

accept_clients :: (server: *Http_Server) {
    while true {
        #if OS == .LINUX {
            client_socket := Socket.accept4(server.listening_socket, null, null, .SOCK_NONBLOCK);
        } else {
            client_socket := Socket.accept(server.listening_socket, null, null);
        }

        if client_socket == Socket.INVALID_SOCKET {
            error := Socket.get_last_socket_error();
            if error == Socket.SOCKET_WOULDBLOCK return;
            continue;
        }

        if server.max_clients > 0 && server.clients.count >= server.max_clients {
            Socket.close_and_reset(*client_socket);
            continue;
        }

        client := add_client(server, client_socket);

        #if OS != .LINUX {
            success := Socket.set_blocking(client_socket, false);
            if !success {
                close(server, client);
                continue;
            }
        }

        no_delay: s32 = 1;
        Socket.setsockopt(client_socket, xx Socket.IPPROTO.IPPROTO_TCP, Socket.TCP_NODELAY, xx *no_delay, size_of(type_of(no_delay)));

        if server.tls {
            client.ssl = LibreSSL.SSL_new(server.ssl_ctx);
            if !client.ssl {
                print_ssl_errors();
                close(server, client);
                continue;
            }

            LibreSSL.SSL_set_fd(client.ssl, xx client_socket);

            result := LibreSSL.SSL_accept(client.ssl);
            if result <= 0 {
                error := LibreSSL.SSL_get_error(client.ssl, result);
                if error != LibreSSL.SSL_ERROR_WANT_READ && error != LibreSSL.SSL_ERROR_WANT_WRITE {
                    print_ssl_errors();
                    close(server, client);
                    continue;
                }
            }
        }

        error := add_to_queue(server, client);
        if error {
            close(server, client);
            continue;
        }

        closed := read_from_client(server, client_socket);
        if !closed parse_requests(server, client_socket);
    }
}

read_from_client :: (server: *Http_Server, client_id: Socket.Socket) -> closed: bool {
    client := find_client(server, client_id);
    if client == null return true;

    client.ssl_read_wants_write = false;

    while true {
        offset := client.read_buffer.data + client.read_buffer.count;
        max    := client.read_buffer.allocated - client.read_buffer.count;

        if max == 0 {
            array_reserve(*client.read_buffer, client.read_buffer.allocated + 4096);

            offset = client.read_buffer.data + client.read_buffer.count;
            max    = client.read_buffer.allocated - client.read_buffer.count;
        }

        bytes_read := recv(server, client, offset, max);
        if bytes_read == -1 {
            error := Socket.get_last_socket_error();

            if server.tls {
                ssl_error := LibreSSL.SSL_get_error(client.ssl, xx bytes_read);
                if ssl_error == {
                    case LibreSSL.SSL_ERROR_WANT_READ;
                        error = Socket.SOCKET_WOULDBLOCK;

                    case LibreSSL.SSL_ERROR_WANT_WRITE;
                        client.ssl_read_wants_write = true;
                        notify_when_sendable(server, client);
                        return false;
                }
            }

            if error != Socket.SOCKET_WOULDBLOCK {
                close(server, client);
                return true;
            }

            return false;
        }

        if bytes_read == 0 {
            close(server, client);
            return true;
        }

        client.read_buffer.count += bytes_read;

        max_read_size := ifx client.type == .Web_Socket then MAX_WEB_SOCKET_MESSAGE_SIZE + 14 else MAX_REQUEST_SIZE;
        if client.read_buffer.count >= max_read_size {
            close(server, client);
            return true;
        }

        if !server.tls && bytes_read < max break;
    }

    return false;
}

handle_send_failure :: (server: *Http_Server, client: *Http_Client, bytes_sent: int) -> closed: bool {
    error := Socket.get_last_socket_error();

    if server.tls {
        ssl_error := LibreSSL.SSL_get_error(client.ssl, xx bytes_sent);
        if ssl_error == {
            case LibreSSL.SSL_ERROR_WANT_READ;
                client.ssl_write_wants_read = true;

                if !client.ssl_read_wants_write do_not_notify_when_sendable(server, client);

                set_timeout(server, client, 30);

                return false;

            case LibreSSL.SSL_ERROR_WANT_WRITE;
                error = Socket.SOCKET_WOULDBLOCK;
        }
    }

    if error != Socket.SOCKET_WOULDBLOCK {
        close(server, client);
        return true;
    }

    set_timeout(server, client, 30);
    notify_when_sendable(server, client);

    return false;
}

send_to_client :: (server: *Http_Server, client_id: Socket.Socket) -> closed: bool {
    client := find_client(server, client_id);
    if client == null return true;

    if MAX_SEND_BUFFER_SIZE > 0 && client.send_buffer.count - client.send_buffer_offset > MAX_SEND_BUFFER_SIZE {
        close(server, client);
        return true;
    }

    client.ssl_write_wants_read = false;

    while client.send_buffer.count - client.send_buffer_offset > 0 {
        bytes_sent := send(server, client, client.send_buffer.data + client.send_buffer_offset, client.send_buffer.count - client.send_buffer_offset);
        if bytes_sent == -1 {
            return handle_send_failure(server, client, bytes_sent);
        }

        client.send_buffer_offset += bytes_sent;
    }

    if client.send_buffer_offset == client.send_buffer.count {
        client.send_buffer_offset = 0;
        client.send_buffer.count = 0;
    } else if client.send_buffer_offset >= 4096 {
        remaining := client.send_buffer.count - client.send_buffer_offset;
        memcpy(client.send_buffer.data, client.send_buffer.data + client.send_buffer_offset, remaining);
        client.send_buffer.count = remaining;
        client.send_buffer_offset = 0;
    }

    if client.send_file.handle {
        #if OS == .LINUX {
            if !server.tls {
                file_fd := POSIX.fileno(client.send_file.handle);

                while client.send_file_offset < client.send_file_end {
                    remaining := client.send_file_end - client.send_file_offset;
                    offset: s64 = client.send_file_offset;
                    bytes_sent := linux_sendfile(client.client_id, file_fd, *offset, xx remaining);

                    if bytes_sent == -1 {
                        return handle_send_failure(server, client, -1);
                    }

                    if bytes_sent == 0 break;

                    client.send_file_offset = offset;

                    if bytes_sent < remaining {
                        set_timeout(server, client, 30);
                        notify_when_sendable(server, client);
                        return false;
                    }
                }

                file_close(*client.send_file);

                client.send_file_offset = 0;
                client.send_file_end    = 0;
            }
        } else #if OS == .MACOS {
            if !server.tls {
                file_fd := POSIX.fileno(client.send_file.handle);

                while client.send_file_offset < client.send_file_end {
                    remaining := client.send_file_end - client.send_file_offset;
                    bytes_sent: s64 = remaining;
                    result := Socket.sendfile(file_fd, client.client_id, client.send_file_offset, *bytes_sent, null, 0);

                    client.send_file_offset += bytes_sent;

                    if result == -1 {
                        return handle_send_failure(server, client, -1);
                    }

                    if bytes_sent == 0 break;
                }

                file_close(*client.send_file);

                client.send_file_offset = 0;
                client.send_file_end    = 0;
            }
        }

        if client.send_file.handle {
            buffer: [32768] u8;

            while client.send_file_offset < client.send_file_end {
                to_read := min(client.send_file_end - client.send_file_offset, buffer.count);

                success := file_set_position(client.send_file, client.send_file_offset);
                if !success {
                    close(server, client);
                    return true;
                }

                bytes_read: int;
                success, bytes_read = file_read(client.send_file, buffer.data, to_read);
                if !success || bytes_read == 0 {
                    close(server, client);
                    return true;
                }

                remaining_data  := buffer.data;
                remaining_count := bytes_read;
                while remaining_count > 0 {
                    bytes_sent := send(server, client, remaining_data, remaining_count);
                    if bytes_sent == -1 {
                        return handle_send_failure(server, client, bytes_sent);
                    }

                    client.send_file_offset += bytes_sent;
                    remaining_data          += bytes_sent;
                    remaining_count         -= bytes_sent;
                }
            }

            file_close(*client.send_file);

            client.send_file_offset = 0;
            client.send_file_end    = 0;
        }
    }

    if client.close_after_send {
        close(server, client);
        return true;
    }

    if !client.ssl_read_wants_write do_not_notify_when_sendable(server, client);
    set_timeout(server, client, 30);

    client.waiting_for_response = false;

    if client.read_buffer.count > 0 && client.type != .SSE && !client.is_in_pending_reads {
        client.is_in_pending_reads = true;
        array_add(*server.clients_with_pending_reads, client.client_id);
    }

    return false;
}

client_can_read :: (server: *Http_Server, client_id: Socket.Socket) -> closed: bool {
    client := find_client(server, client_id);
    if client == null return true;

    if client.ssl_write_wants_read {
        closed := send_to_client(server, client_id);
        if closed return true;
    }

    closed := read_from_client(server, client_id);
    if closed return true;

    parse_requests(server, client_id);
    return false;
}

client_can_send :: (server: *Http_Server, client_id: Socket.Socket) -> closed: bool {
    client := find_client(server, client_id);
    if client == null return true;

    if client.ssl_read_wants_write {
        closed := read_from_client(server, client_id);
        if closed return true;

        parse_requests(server, client_id);
    }

    return send_to_client(server, client_id);
}

recv :: (server: *Http_Server, client: *Http_Client, buffer: *u8, size: int) -> int {
    if server.tls {
        return LibreSSL.SSL_read(client.ssl, buffer, xx size);
    }

    return Socket.recv(client.client_id, buffer, xx size, 0);
}

send :: (server: *Http_Server, client: *Http_Client, buffer: *u8, size: int) -> int {
    if server.tls {
        return LibreSSL.SSL_write(client.ssl, buffer, xx size);
    }

    return Socket.send(client.client_id, buffer, xx size, 0);
}

parse_requests :: (server: *Http_Server, client_id: Socket.Socket) {
    client := find_client(server, client_id);
    if client == null return;

    if client.type == {
        case .SSE;
            array_reset(*client.read_buffer);
            return;

        case .Web_Socket;
            parse_web_socket_frames(server, client_id);
            return;

    }

    if client.waiting_for_response  return;
    if client.read_buffer.count == 0 return;

    client.t     = client.read_buffer.data;
    client.max_t = client.read_buffer.data + client.read_buffer.count;

    status, request := parse_request(client);
    if status == .ERROR {
        close(server, client);
        return;
    } else if status == .INCOMPLETE {
        return;
    }

    remaining := client.max_t - client.t;

    if remaining > 0 {
        memcpy(client.read_buffer.data, client.t, remaining);
    }

    client.read_buffer.count = remaining;

    client.waiting_for_response = true;

    request.client_id = client_id;

    set_timeout(server, client, 30);

    array_add(*server.events, .{ type = .Http_Request, http_request = request });
}

parse_request :: (using client: *Http_Client) -> Parse_Status, Http_Request {
    request: Http_Request;

    status := parse_request_line(client, *request);
    if status != .SUCCESS return status, .{};

    if t >= max_t return .INCOMPLETE, .{};

    content_length := -1;

    while true {
        if t.* == "\r" {
            t += 1;
            if t >= max_t  return .INCOMPLETE, .{};
            if t.* != "\n" return .ERROR, .{};

            t += 1;
            break;
        }

        status, header := parse_header(client);
        if status != .SUCCESS return status, .{};

        if equal_nocase(header.key, "Content-Length") {
            if content_length != -1 return .ERROR, .{};

            content_length=, success:, remainder := string_to_int(header.value, T = u32);
            if !success || remainder.count > 0 return .ERROR, .{};
        } else if equal_nocase(header.key, "Transfer-Encoding") {
            return .ERROR, .{};
        }

        array_add(*request.headers, header);
    }

    if content_length != -1 {
        if t + content_length > max_t return .INCOMPLETE, .{};

        request.body.data  = t;
        request.body.count = content_length;

        t += content_length;
    }

    request.uri = copy_temporary_string(request.uri);

    for * request.headers {
        it.key   = copy_temporary_string(it.key);
        it.value = copy_temporary_string(it.value);
    }

    if request.body.count > 0 {
        request.body = copy_temporary_string(request.body);
    }

    return .SUCCESS, request;
}

parse_request_line :: (using client: *Http_Client, request: *Http_Request) -> Parse_Status {
    method := string.{ data = t };

    while t < max_t {
        if t - method.data > 7    return .ERROR;
        if t.* == " "             break;
        if t.* < "A" || t.* > "Z" return .ERROR;

        t += 1;
    }

    if t >= max_t return .INCOMPLETE;

    method.count = t - method.data;

    if method == {
        case "GET";     request.method = .GET;
        case "HEAD";    request.method = .HEAD;
        case "POST";    request.method = .POST;
        case "PUT";     request.method = .PUT;
        case "DELETE";  request.method = .DELETE;
        case "CONNECT"; request.method = .CONNECT;
        case "OPTIONS"; request.method = .OPTIONS;
        case "TRACE";   request.method = .TRACE;
        case "PATCH";   request.method = .PATCH;

        case; return .ERROR;
    }

    t += 1;
    if t >= max_t return .INCOMPLETE;

    request.uri.data = t;

    while t < max_t {
        if t.* == " " break;

        if !URI_ALLOWED_CHARS[t.*] return .ERROR;

        t += 1;
    }

    if t >= max_t return .INCOMPLETE;

    request.uri.count = t - request.uri.data;

    t += 1;
    if t >= max_t return .INCOMPLETE;

    version := string.{ data = t };

    while t < max_t {
        if t - version.data > 8 return .ERROR;

        if t.* == "\r" {
            t += 1;
            if t >= max_t  return .INCOMPLETE;
            if t.* != "\n" return .ERROR;

            break;
        }

        version.count += 1;
        t += 1;
    }

    if t >= max_t return .INCOMPLETE;

    if version != "HTTP/1.1" return .ERROR;

    t += 1;
    if t >= max_t return .INCOMPLETE;

    return .SUCCESS;
}

parse_header :: (using client: *Http_Client) -> Parse_Status, Http_Header {
    header: Http_Header;
    header.key.data = t;

    while t < max_t {
        if t.* == ":" break;
        if !HEADER_KEY_ALLOWED_CHARS[t.*] return .ERROR, .{};

        t += 1;
    }

    if t >= max_t return .INCOMPLETE, .{};

    header.key.count = t - header.key.data;
    if header.key.count == 0 return .ERROR, .{};

    t += 1;
    if t >= max_t return .INCOMPLETE, .{};

    header.value.data = t;

    while t < max_t {
        if t.* == "\r" {
            t += 1;
            if t >= max_t  return .INCOMPLETE, .{};
            if t.* != "\n" return .ERROR, .{};

            break;
        }

        if (t.* < 0x20 && t.* != #char "\t") || t.* == 0x7F return .ERROR, .{};

        t += 1;
    }

    header.value.count = t - header.value.data;
    header.value = trim(header.value, chars=" \t\r");

    t += 1;
    if t >= max_t return .INCOMPLETE, .{};

    return .SUCCESS, header;
}

set_timeout :: (server: *Http_Server, using client: *Http_Client, seconds: int) {
    timeout = current_time_monotonic() + seconds_to_apollo(seconds);

    if !server.has_next_client_timeout || timeout < server.next_client_timeout {
        server.next_client_timeout     = timeout;
        server.has_next_client_timeout = true;
    }
}

process_timeouts_and_get_next_timeout :: (server: *Http_Server) -> int {
    now := current_time_monotonic();
    earliest := -1;

    if server.clients.count == 0 {
        server.has_next_client_timeout = false;
    } else if server.has_next_client_timeout && now < server.next_client_timeout {
        earliest = to_milliseconds(server.next_client_timeout - now);
    } else {
        timed_out_clients: [..] Socket.Socket;
        timed_out_clients.allocator = temp;

        server.has_next_client_timeout = false;

        for * server.clients {
            if it.timeout <= now {
                array_add(*timed_out_clients, it.client_id);
                continue;
            }

            if !server.has_next_client_timeout || it.timeout < server.next_client_timeout {
                server.next_client_timeout     = it.timeout;
                server.has_next_client_timeout = true;
            }
        }

        for timed_out_clients {
            client := find_client(server, it);
            if client close(server, client);
        }

        if server.has_next_client_timeout {
            earliest = to_milliseconds(server.next_client_timeout - now);
        }
    }

    for * server.timers {
        if it.timeout <= now {
            array_add(*server.events, .{ type = .Timer, timer = it.id });
            remove it;
            continue;
        }

        this := to_milliseconds(it.timeout - now);
        if earliest == -1 || this < earliest earliest = this;
    }

    return earliest;
}

close_in_next_iteration :: (server: *Http_Server, client: *Http_Client) {
    array_add(*server.clients_to_close_in_next_iteration, client.client_id);
}

close :: (server: *Http_Server, client: *Http_Client, now := false) {
    should_close_in_next_iteration  := !now;
    should_close_in_next_iteration &&= client.type == .Web_Socket || client.type == .SSE;

    if should_close_in_next_iteration {
        array_add(*server.clients_to_close_in_next_iteration, client.client_id);
        return;
    }

    #if OS == .WINDOWS {
        for server.wsapollfds {
            if it.fd == client.client_id {
                remove it;
                break;
            }
        }
    }

    if server.tls && client.ssl {
        LibreSSL.SSL_shutdown(client.ssl);
        LibreSSL.SSL_free(client.ssl);
    }

    socket := client.client_id;
    Socket.close_and_reset(*socket);
    remove_client(server, client);
}

add_client :: (server: *Http_Server, client_id: Socket.Socket) -> *Http_Client {
    client := table_add(*server.clients, client_id, .{});
    client.client_id = client_id;

    set_timeout(server, client, 5);

    return client;
}

find_client :: (server: *Http_Server, client_id: Socket.Socket) -> *Http_Client {
    client := table_find_pointer(*server.clients, client_id);
    return client;
}

remove_client :: (server: *Http_Server, client: *Http_Client) {
    for * server.events {
        if it.type == {
            case .Http_Request;
                if it.http_request.client_id == client.client_id remove it;

            case .Web_Socket_Message;
                if it.web_socket_message.client_id == client.client_id remove it;
        }
    }

    client_id := client.client_id;

    array_reset(*client.read_buffer);
    array_reset(*client.send_buffer);
    array_reset(*client.ws_partial_payload);

    if client.send_file.handle file_close(*client.send_file);

    table_remove(*server.clients, client_id);
}

create_and_bind_listening_socket :: (server: *Http_Server, address: string, port: u16) -> error: bool {
    ip   := ifx address == "localhost" then "127.0.0.1" else address;
    c_ip := temp_c_string(ip);

    ipv4: u32;
    ipv6: [16] u8;

    socket := Socket.INVALID_SOCKET;

    if Socket.inet_pton(Socket.AF_INET, c_ip, *ipv4) == 1 {
        socket = Socket.socket(Socket.AF_INET, .SOCK_STREAM, Socket.IPPROTO.IPPROTO_TCP);
        if socket == Socket.INVALID_SOCKET return true;

        #if OS == .LINUX || OS == .MACOS {
            options: s32 = 1;
            result := Socket.setsockopt(socket, Socket.SOL_SOCKET, Socket.SO_REUSEPORT, *options, size_of(type_of(options)));
            if result == -1 {
                Socket.close_and_reset(*socket);
                return true;
            }
        }

        #if OS == .WINDOWS {
            result := Socket.bind(socket, Socket.ntohl(ipv4), port);
        } else {
            result = Socket.bind(socket, Socket.ntohl(ipv4), port);
        }

        if result != 0 {
            Socket.close_and_reset(*socket);
            return true;
        }
    } else if Socket.inet_pton(Socket.AF_INET6, c_ip, ipv6.data) == 1 {
        socket = Socket.socket(Socket.AF_INET6, .SOCK_STREAM, Socket.IPPROTO.IPPROTO_TCP);
        if socket == Socket.INVALID_SOCKET return true;

        v6_only: s32 = 0;
        result := Socket.setsockopt(socket, xx Socket.IPPROTO.IPPROTO_IPV6, Socket.IPV6_V6ONLY, xx *v6_only, size_of(type_of(v6_only)));
        if result == -1 {
            Socket.close_and_reset(*socket);
            return true;
        }

        #if OS == .LINUX || OS == .MACOS {
            options: s32 = 1;
            result = Socket.setsockopt(socket, Socket.SOL_SOCKET, Socket.SO_REUSEPORT, *options, size_of(type_of(options)));
            if result == -1 {
                Socket.close_and_reset(*socket);
                return true;
            }
        }

        result = Socket.bind(socket, ipv6, port);
        if result != 0 {
            Socket.close_and_reset(*socket);
            return true;
        }
    } else {
        return true;
    }

    no_delay: s32 = 1;
    Socket.setsockopt(socket, xx Socket.IPPROTO.IPPROTO_TCP, Socket.TCP_NODELAY, xx *no_delay, size_of(type_of(no_delay)));

    result := Socket.listen(socket, Socket.SOMAXCONN);
    if result != 0 {
        Socket.close_and_reset(*socket);
        return true;
    }

    success := Socket.set_blocking(socket, false);
    if !success {
        Socket.close_and_reset(*socket);
        return true;
    }

    server.listening_socket = socket;

    return false;
}

create_wake_up_socket :: (server: *Http_Server) -> error: bool {
    socket := Socket.socket(Socket.AF_INET, .SOCK_DGRAM, 0);
    if socket == Socket.INVALID_SOCKET return true;

    result := Socket.bind(socket, 0x7F000001, 0);
    if result != 0 {
        Socket.close_and_reset(*socket);
        return true;
    }

    addr: Socket.sockaddr_in;
    #if OS == .WINDOWS {
        addr_size: s32 = size_of(type_of(addr));
    } else {
        addr_size: u32 = size_of(type_of(addr));
    }

    result = Socket.getsockname(socket, cast(*Socket.sockaddr)*addr, *addr_size);
    if result != 0 {
        Socket.close_and_reset(*socket);
        return true;
    }

    success := Socket.set_blocking(socket, false);
    if !success {
        Socket.close_and_reset(*socket);
        return true;
    }

    server.wake_up_socket = socket;
    server.wake_up_port   = Socket.ntohs(addr.sin_port);

    return false;
}

configure_max_clients :: (server: *Http_Server) {
    #if OS == .LINUX || OS == .MACOS {
        limit: POSIX.rlimit;
        result := POSIX.getrlimit(.RLIMIT_NOFILE, *limit);
        if result == 0 {
            active_limit := limit.rlim_cur;

            limit.rlim_cur = limit.rlim_max;
            result = POSIX.setrlimit(.RLIMIT_NOFILE, *limit);
            if result == 0 active_limit = limit.rlim_cur;

            fd_max := (cast(int) active_limit - 32) / 2;
            if fd_max < 1 fd_max = 1;

            if MAX_CLIENTS > 0 server.max_clients = min(MAX_CLIENTS, fd_max);
            else               server.max_clients = fd_max;
            return;
        }
    }

    server.max_clients = MAX_CLIENTS;
}

create_ssl_context :: () -> *LibreSSL.SSL_CTX {
    method := LibreSSL.TLS_server_method();
    ctx    := LibreSSL.SSL_CTX_new(method);
    if !ctx {
        print_ssl_errors();
        return null;
    }

    return ctx;
}

configure_ssl_context :: (ctx: *LibreSSL.SSL_CTX, certificate_file: string, private_key_file: string) -> error: bool {
    result := LibreSSL.SSL_CTX_use_certificate_chain_file(ctx, temp_c_string(certificate_file));
    if result <= 0 {
        print_ssl_errors();
        return true;
    }

    result = LibreSSL.SSL_CTX_use_PrivateKey_file(ctx, temp_c_string(private_key_file), LibreSSL.SSL_FILETYPE_PEM);
    if result <= 0 {
        print_ssl_errors();
        return true;
    }

    result = LibreSSL.SSL_CTX_check_private_key(ctx);
    if result <= 0 {
        print_ssl_errors();
        return true;
    }

    return false;
}

print_ssl_errors :: () {
    #if OS == .WINDOWS {
        buffer: [1024] u8;

        bio := LibreSSL.BIO_new(LibreSSL.BIO_s_mem());
        LibreSSL.ERR_print_errors(bio);

        count      := LibreSSL.BIO_read(bio, buffer.data, buffer.count);
        serialized := string.{ data = buffer.data, count = count };

        if count > 0 {
            print("%\n", serialized);
        }

        LibreSSL.BIO_free(bio);
    } else {
        LibreSSL.ERR_print_errors_fp(POSIX.stderr);
    }
}

kilobytes :: (n: int) -> int {
    return n * 1024;
}

parse_range :: (header: string) -> error: bool, start: int, end: int {
    t     := header.data;
    max_t := header.data + header.count;

    key := string.{ data = t };

    while t < max_t {
        if t - key.data > #run "bytes".count return true, 0, 0;
        if t.* == "="                        break;
        if !is_alpha(t.*)                    return true, 0, 0;

        t += 1;
    }

    key.count = t - key.data;

    if !equal_nocase(key, "bytes") return true, 0, 0;

    if t.* != "=" return true, 0, 0;
    t += 1;

    if t >= max_t return true, 0, 0;

    start := string.{ data = t };

    while t < max_t {
        if t.* == "-"     break;
        if !is_digit(t.*) return true, 0, 0;

        t += 1;
    }

    start.count = t - start.data;
    if start.count > 18 return true, 0, 0;

    if t.* != "-" return true, 0, 0;

    t += 1;
    if t >= max_t {
        if start.count == 0 return true, 0, 0;
        return false, string_to_int(start), -1;
    }

    end := string.{ data = t };

    while t < max_t {
        if !is_digit(t.*) return true, 0, 0;

        t += 1;
    }

    end.count = t - end.data;
    if end.count > 18 return true, 0, 0;
    if start.count == 0 && end.count == 0 return true, 0, 0;

    start_int := ifx start.count == 0 then -1 else string_to_int(start);
    end_int   := ifx end.count == 0 then -1 else string_to_int(end);
    return false, start_int, end_int;
}

serve_entire_static_file :: (request: Http_Request, path: string) -> Http_Response {
    response: Http_Response;
    response.client_id = request.client_id;
    response.status    = .OK;

    set_header(*response.headers, "Accept-Ranges", "bytes");

    content_type := get_content_type_from_extension(path);
    set_header(*response.headers, "Content-Type", content_type);

    file, success := file_open(path);
    if !success return internal_server_error(request);

    response.file = file;

    length:, success = file_length(file);
    if !success {
        file_close(*file);
        return internal_server_error(request);
    }

    response.file_offset = 0;
    response.file_size   = length;

    set_header(*response.headers, "Content-Length", tprint("%", length));

    return response;
}

serve_static_file_range :: (request: Http_Request, path: string) -> Http_Response {
    response: Http_Response;
    response.client_id = request.client_id;
    response.status    = .PARTIAL_CONTENT;

    content_type := get_content_type_from_extension(path);
    set_header(*response.headers, "Content-Type", content_type);

    error, range := get_header(request.headers, "Range");
    if error return internal_server_error(request);

    error=, start, end := parse_range(range);
    if error return bad_request(request);

    file, success := file_open(path);
    if !success return internal_server_error(request);

    length:, success = file_length(file);
    if !success {
        file_close(*file);
        return internal_server_error(request);
    }

    if start == -1 {
        if end <= 0 {
            file_close(*file);
            return bad_request(request);
        }
        start = length - end;
        if start < 0 start = 0;
        end = length - 1;
    }

    if start >= length {
        file_close(*file);
        response.status = .RANGE_NOT_SATISFIABLE;
        set_header(*response.headers, "Content-Range", tprint("bytes */%", length));
        return response;
    }

    if end == -1 {
        end = start + kilobytes(1024);
    }

    if end >= length end = length - 1;
    if start > end {
        file_close(*file);
        return bad_request(request);
    }

    if end - start + 1 > kilobytes(1024) {
        end = start + kilobytes(1024) - 1;
    }

    count := end - start + 1;

    response.file        = file;
    response.file_offset = start;
    response.file_size   = count;

    set_header(*response.headers, "Content-Length", tprint("%", count));
    set_header(*response.headers, "Content-Range", tprint("bytes %-%/%", start, end, length));

    return response;
}

get_content_type_from_extension :: (path: string) -> string {
    extension := path_extension(path);

    if extension == {
        // Text/HTML/CSS/JS
        case "html"; return "text/html";
        case "css";  return "text/css";
        case "js";   return "application/javascript";
        case "json"; return "application/json";
        case "txt";  return "text/plain";
        case "wasm"; return "application/wasm";

        // Images
        case "jpg";  #through;
        case "jpeg"; return "image/jpeg";
        case "png";  return "image/png";
        case "gif";  return "image/gif";
        case "webp"; return "image/webp";
        case "svg";  return "image/svg+xml";
        case "ico";  return "image/x-icon";
        case "bmp";  return "image/bmp";
        case "tif";  #through;
        case "tiff"; return "image/tiff";
        case "avif"; return "image/avif";

        // Video
        case "webm"; return "video/webm";
        case "mp4";  return "video/mp4";
        case "mkv";  return "video/x-matroska";
        case "avi";  return "video/x-msvideo";
        case "mov";  return "video/quicktime";

        // Audio
        case "mp3";  return "audio/mpeg";
        case "wav";  return "audio/wav";
        case "ogg";  return "audio/ogg";
        case "m4a";  return "audio/mp4";
        case "flac"; return "audio/flac";

        // Documents
        case "pdf";  return "application/pdf";
    }

    return "application/octet-stream";
}

Parse_Status :: enum {
    ERROR;
    INCOMPLETE;
    SUCCESS;
}

Http_Client_Type :: enum {
    Http;
    SSE;
    Web_Socket;
}

Http_Client :: struct {
    type: Http_Client_Type;

    client_id: Socket.Socket;
    timeout:   Apollo_Time;

    t:     *u8;
    max_t: *u8;

    read_buffer: [..] u8;
    send_buffer: [..] u8;
    send_buffer_offset: int;

    ssl: *LibreSSL.SSL;
    ssl_read_wants_write: bool;
    ssl_write_wants_read: bool;

    send_file:        File;
    send_file_offset: int;
    send_file_end:    int;

    ws_partial_opcode:  u8;
    ws_partial_payload: [..] u8;

    close_after_send:           bool;
    is_notifying_when_sendable: bool;
    waiting_for_response:       bool;
    is_in_pending_reads:        bool;
}

#insert -> string {
    push_allocator(temp);

    Http_Response_Status_Specification :: struct {
        key:         string;
        code:        int;
        description: string;
    }

    response_status_specifications := Http_Response_Status_Specification.[
        .{ "NONE", 0, "None" },

        .{ "CONTINUE",            100, "Continue" },
        .{ "SWITCHING_PROTOCOLS", 101, "Switching Protocols" },
        .{ "EARLY_HINTS",         103, "Early Hints" },

        .{ "OK",                            200, "OK" },
        .{ "CREATED",                       201, "Created" },
        .{ "ACCEPTED",                      202, "Accepted" },
        .{ "NON_AUTHORITATIVE_INFORMATION", 203, "Non Authoritative Information" },
        .{ "NO_CONTENT",                    204, "No Content" },
        .{ "RESET_CONTENT",                 205, "Reset Content" },
        .{ "PARTIAL_CONTENT",               206, "Partial Content" },

        .{ "MULTIPLE_CHOICES",   300, "Multiple Choices" },
        .{ "MOVED_PERMANENTLY",  301, "Moved Permanently" },
        .{ "FOUND",              302, "Found" },
        .{ "SEE_OTHER",          303, "See Other" },
        .{ "NOT_MODIFIED",       304, "Not Modified" },
        .{ "TEMPORARY_REDIRECT", 307, "Temporary Redirect" },
        .{ "PERMANENT_REDIRECT", 308, "Permanent Redirect" },

        .{ "BAD_REQUEST",                     400, "Bad Request" },
        .{ "UNAUTHORIZED",                    401, "Unauthorized" },
        .{ "PAYMENT_REQUIRED",                402, "Payment Required" },
        .{ "FORBIDDEN",                       403, "Forbidden" },
        .{ "NOT_FOUND",                       404, "Not Found" },
        .{ "METHOD_NOT_ALLOWED",              405, "Method Not Allowed" },
        .{ "NOT_ACCEPTABLE",                  406, "Not Acceptable" },
        .{ "PROXY_AUTHENTICATION_REQUIRED",   407, "Proxy Authentication Required" },
        .{ "REQUEST_TIMEOUT",                 408, "Request Timeout" },
        .{ "CONFLICT",                        409, "Conflict" },
        .{ "GONE",                            410, "Gone" },
        .{ "LENGTH_REQUIRED",                 411, "Length Required" },
        .{ "PRECONDITION_FAILED",             412, "Precondition Failed" },
        .{ "CONTENT_TOO_LARGE",               413, "Content Too Large" },
        .{ "URI_TOO_LONG",                    414, "URI Too Long" },
        .{ "UNSUPPORTED_MEDIA_TYPE",          415, "Unsupported Media Type" },
        .{ "RANGE_NOT_SATISFIABLE",           416, "Range Not Satisfiable" },
        .{ "EXPECTATION_FAILED",              417, "Expectation Failed" },
        .{ "I_AM_A_TEAPOT",                   418, "I'm a teapot" },
        .{ "MISDIRECTED_REQUEST",             421, "Misdirected Request" },
        .{ "UPGRADE_REQUIRED",                426, "Upgrade Required" },
        .{ "PRECONDITION_REQUIRED",           428, "Precondition Required" },
        .{ "TOO_MANY_REQUESTS",               429, "Too Many Requests" },
        .{ "REQUEST_HEADER_FIELDS_TOO_LARGE", 431, "Request Header Fields Too Large" },
        .{ "UNAVAILABLE_FOR_LEGAL_REASONS",   451, "Unavailable For Legal Reasons" },

        .{ "INTERNAL_SERVER_ERROR",           500, "Internal Server Error" },
        .{ "NOT_IMPLEMENTED",                 501, "Not Implemented" },
        .{ "BAD_GATEWAY",                     502, "Bad Gateway" },
        .{ "SERVICE_UNAVAILABLE",             503, "Service Unavailable" },
        .{ "GATEWAY_TIMEOUT",                 504, "Gateway Timeout" },
        .{ "HTTP_VERSION_NOT_SUPPORTED",      505, "HTTP Version Not Supported" },
        .{ "VARIANT_ALSO_NEGOTIATES",         506, "Variant Also Negotiates" },
        .{ "NOT_EXTENDED",                    510, "Not Extended" },
        .{ "NETWORK_AUTHENTICATION_REQUIRED", 511, "Network Authentication Required" },
    ];

    b: String_Builder;

    append(*b, "Http_Response_Status :: enum {\n");

    for response_status_specifications {
        print_to_builder(*b, "    % :: %; \n", it.key, it.code);
    }

    append(*b, "}\n\n");

    append(*b, "http_response_status_to_string :: (response_status: Http_Response_Status) -> string {\n");
    append(*b, "    if #complete response_status == {\n");

    for response_status_specifications {
        print_to_builder(*b, "        case .%;  return \"% %\";\n", it.key, it.code, it.description);
    }

    append(*b, "    }\n");
    append(*b, "}\n");

    return builder_to_string(*b);
}

#no_reset
URI_ALLOWED_CHARS: [256] bool;

#no_reset
HEADER_KEY_ALLOWED_CHARS: [256] bool;

#run {
    for #char "a"..#char "z"      URI_ALLOWED_CHARS[it]  = true;
    for #char "A"..#char "Z"      URI_ALLOWED_CHARS[it]  = true;
    for #char "0"..#char "9"      URI_ALLOWED_CHARS[it]  = true;
    for "-._~!$&'()*+,;=:@/?#[]%" URI_ALLOWED_CHARS[it] = true;

    for #char "a"..#char "z" HEADER_KEY_ALLOWED_CHARS[it] = true;
    for #char "A"..#char "Z" HEADER_KEY_ALLOWED_CHARS[it] = true;
    for #char "0"..#char "9" HEADER_KEY_ALLOWED_CHARS[it] = true;
    for "!#$%&'*+-.^_`|~"    HEADER_KEY_ALLOWED_CHARS[it] = true;
}

#load "router.jai";
#load "sse.jai";
#load "web_socket.jai";

#import "Base64";
#import "Basic";
#import "File";
#import "File_Utilities";
#import "Flat_Pool";
#import "Hash_Table";
#import "Math";
#import "String";
#import "Unicode";

Socket   :: #import "Socket";
LibreSSL :: #import,dir "../LibreSSL";

#if OS == .LINUX {
    #load "linux.jai";
    Linux :: #import "Linux";
    POSIX :: #import "POSIX";
}

#if OS == .MACOS {
    #load "macos.jai";
    Macos :: #import "Macos";
    POSIX :: #import "POSIX";
}

#if OS == .WINDOWS {
    #load "windows.jai";
}
