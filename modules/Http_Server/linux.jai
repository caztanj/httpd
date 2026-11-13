init :: (server: *Http_Server, port: u16, address := "127.0.0.1", tls := false, certificate_file := "", private_key_file := "", threads := 1) -> error: bool {
    POSIX.signal(POSIX.SIGPIPE, POSIX.SIG_IGN);

    server.epoll_queue = Linux.epoll_create1(0);
    if server.epoll_queue == -1 return true;

    error := create_and_bind_listening_socket(server, address, port);
    if error return true;

    event: Linux.epoll_event;
    event.events = Linux.EPOLLET | Linux.EPOLLIN;
    event.data.fd = server.listening_socket;

    result := Linux.epoll_ctl(server.epoll_queue, .ADD, server.listening_socket, *event);
    if result == -1 return true;

    if tls {
        server.ssl_ctx = create_ssl_context();
        if server.ssl_ctx == null return true;

        error = configure_ssl_context(server.ssl_ctx, certificate_file, private_key_file);
        if error return true;
    }

    error = create_wake_up_socket(server);
    if error return true;

    wake_up_event: Linux.epoll_event;
    wake_up_event.events = Linux.EPOLLET | Linux.EPOLLIN;
    wake_up_event.data.fd = server.wake_up_socket;

    Linux.epoll_ctl(server.epoll_queue, .ADD, server.wake_up_socket, *wake_up_event);

    configure_max_clients(server, threads);

    server.tls = tls;

    return false;
}

http_server_poll :: (server: *Http_Server, peek := false) -> error: bool, [] Http_Event {
    push_allocator(context.default_allocator);

    array_reset(*server.events);

    for server.clients_to_close_in_next_iteration {
        client := find_client(server, it);
        if client close(server, client, now = true);
    }

    array_reset(*server.clients_to_close_in_next_iteration);

    for server.clients_with_pending_reads {
        client := find_client(server, it);
        if client {
            client.is_in_pending_reads = false;
            parse_requests(server, it);
        }
    }

    array_reset_keeping_memory(*server.clients_with_pending_reads);

    timeout := process_timeouts_and_get_next_timeout(server);
    if peek || server.events.count > 0 timeout = 0;

    epoll_events: [1024] Linux.epoll_event;
    number_of_events := Linux.epoll_wait(server.epoll_queue, epoll_events.data, epoll_events.count, xx timeout);
    if number_of_events == -1 return true, .[];

    for i: 0..number_of_events - 1 {
        event := epoll_events[i];

        if event.data.fd == server.wake_up_socket {
            buffer: [64] u8;
            Socket.recvfrom(server.wake_up_socket, buffer.data, 64, 0, null, null);
            continue;
        }

        error_events :: Linux.EPOLLPRI | Linux.EPOLLERR | Linux.EPOLLHUP;

        if event.data.fd == server.listening_socket {
            if event.events & Linux.EPOLLIN accept_clients(server);
            if event.events & error_events return true, .[];
            continue;
        }

        client_id := event.data.fd;

        if event.events & error_events {
            client := find_client(server, client_id);
            if client close(server, client);
            continue;
        }

        if event.events & Linux.EPOLLOUT {
            closed := client_can_send(server, client_id);
            if closed continue;
        }

        if event.events & Linux.EPOLLIN {
            closed := client_can_read(server, client_id);
            if closed continue;
        }
    }

    // If a WebSocket times out and receives a socket error in the same poll cycle,
    // it can be queued for closure multiple times. This means duplicate .Client_Closed
    // events may be emitted for the same client in this array.
    for server.clients_to_close_in_next_iteration array_add(*server.events, .{ type = .Client_Closed, client_closed = it });

    return false, server.events;
}

Http_Server :: struct {
    epoll_queue:      s32;
    listening_socket: Socket.Socket;

    clients:     Table(Socket.Socket, Http_Client);
    max_clients: int;

    next_client_timeout:     Apollo_Time;
    has_next_client_timeout: bool;

    clients_to_close_in_next_iteration: [..] Socket.Socket;
    clients_with_pending_reads:         [..] Socket.Socket;

    events: [..] Http_Event;
    events.allocator = temp;

    timers: [..] Http_Timer;
    next_timer_id: u64 = 1;

    tls:     bool;
    ssl_ctx: *LibreSSL.SSL_CTX;

    wake_up_socket: Socket.Socket;
    wake_up_port:   u16;
}

#scope_module

add_to_queue :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    event: Linux.epoll_event;
    event.events = Linux.EPOLLET | Linux.EPOLLIN;
    event.data.fd = client.client_id;

    result := Linux.epoll_ctl(server.epoll_queue, .ADD, client.client_id, *event);
    if result == -1 return true;

    return false;
}

notify_when_sendable :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    if client.is_notifying_when_sendable return false;

    event: Linux.epoll_event;
    event.events = Linux.EPOLLET | Linux.EPOLLIN | Linux.EPOLLOUT;
    event.data.fd = client.client_id;

    result := Linux.epoll_ctl(server.epoll_queue, .MOD, client.client_id, *event);
    if result == -1 return true;

    client.is_notifying_when_sendable = true;

    return false;
}

do_not_notify_when_sendable :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    if !client.is_notifying_when_sendable return false;

    event: Linux.epoll_event;
    event.events = Linux.EPOLLET | Linux.EPOLLIN;
    event.data.fd = client.client_id;

    result := Linux.epoll_ctl(server.epoll_queue, .MOD, client.client_id, *event);
    if result == -1 return true;

    client.is_notifying_when_sendable = false;

    return false;
}

linux_sendfile :: (out_fd: s32, in_fd: s32, offset: *s64, count: u64) -> s64 #foreign libc "sendfile";

#scope_file

libc :: #system_library "libc";