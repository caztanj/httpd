init :: (server: *Http_Server, port: u16, address := "127.0.0.1", tls := false, certificate_file := "", private_key_file := "") -> error: bool {
    server.kqueue = Macos.kqueue();
    if server.kqueue == -1 return true;

    error := create_and_bind_listening_socket(server, address, port);
    if error return true;

    event: Macos.Kevent64;
    event.ident = xx server.listening_socket;
    event.filter = .READ;
    event.flags = .ADD | .ENABLE;

    array_add(*server.kqueue_changes, event);

    if tls {
        server.ssl_ctx = create_ssl_context();
        if server.ssl_ctx == null return true;

        error = configure_ssl_context(server.ssl_ctx, certificate_file, private_key_file);
        if error return true;
    }

    error = create_wake_up_socket(server);
    if error return true;

    wake_up_event: Macos.Kevent64;
    wake_up_event.ident = xx server.wake_up_socket;
    wake_up_event.filter = .READ;
    wake_up_event.flags = .ADD | .ENABLE;

    array_add(*server.kqueue_changes, wake_up_event);

    configure_max_clients(server);

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

    timeout := process_timeouts_and_get_next_timeout(server);

    if peek || server.events.count > 0 timeout = 0;

    timespec: POSIX.timespec;
    if timeout >= 0 {
        timespec.tv_sec = timeout / 1000;
        timespec.tv_nsec = (timeout % 1000) * 1000000;
    }

    kevents: [1024] Macos.Kevent64;
    number_of_events := Macos.kevent64(
        server.kqueue,
        server.kqueue_changes.data,
        xx server.kqueue_changes.count,
        kevents.data,
        xx kevents.count,
        0,
        ifx timeout == -1 && !peek null else *timespec
    );
    if number_of_events == -1 return true, .[];

    array_reset_keeping_memory(*server.kqueue_changes);

    for i: 0..number_of_events - 1 {
        event := kevents[i];

        if event.ident == xx server.wake_up_socket {
            buffer: [64] u8;
            Socket.recvfrom(server.wake_up_socket, buffer.data, 64, 0, null, null);
            continue;
        }

        if event.ident == xx server.listening_socket {
            if event.flags & .ERROR return true, .[];
            accept_clients(server);
            continue;
        }

        client_id := event.ident.(Socket.Socket);

        if event.flags & .ERROR {
            client := find_client(server, client_id);
            if client close(server, client);
            continue;
        }

        if event.filter == .WRITE {
            closed := client_can_send(server, client_id);
            if closed continue;
        }

        if event.filter == .READ {
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
    kqueue:           s32;
    listening_socket: Socket.Socket;

    clients:     Table(Socket.Socket, Http_Client);
    max_clients: int;

    clients_to_close_in_next_iteration: [..] Socket.Socket;

    events: [..] Http_Event;
    events.allocator = temp;

    timers: [..] Http_Timer;
    next_timer_id: u64 = 1;

    kqueue_changes: [..] Macos.Kevent64;

    tls:     bool;
    ssl_ctx: *LibreSSL.SSL_CTX;

    wake_up_socket: Socket.Socket;
    wake_up_port:   u16;
}

#scope_module

add_to_queue :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    event: Macos.Kevent64;
    event.ident = xx client.client_id;
    event.filter = .READ;
    event.flags = .ADD | .ENABLE;

    array_add(*server.kqueue_changes, event);

    return false;
}

notify_when_sendable :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    event: Macos.Kevent64;
    event.ident = xx client.client_id;
    event.filter = .WRITE;
    event.flags = .ADD | .ENABLE;

    array_add(*server.kqueue_changes, event);

    return false;
}

do_not_notify_when_sendable :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    event: Macos.Kevent64;
    event.ident = xx client.client_id;
    event.filter = .WRITE;
    event.flags = .DELETE;

    array_add(*server.kqueue_changes, event);

    return false;
}