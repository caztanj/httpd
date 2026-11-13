init :: (server: *Http_Server, port: u16, address := "127.0.0.1", tls := false, certificate_file := "", private_key_file := "") -> error: bool {
    Socket.socket_init();

    error := create_and_bind_listening_socket(server, address, port);
    if error return true;

    wsapollfd := Socket.WSAPOLLFD.{ fd = server.listening_socket, events = Socket.POLLIN };
    array_add(*server.wsapollfds, wsapollfd);

    if tls {
        server.ssl_ctx = create_ssl_context();
        if server.ssl_ctx == null return true;

        error = configure_ssl_context(server.ssl_ctx, certificate_file, private_key_file);
        if error return true;
    }

    error = create_wake_up_socket(server);
    if error return true;

    wsapollfd_wake_up := Socket.WSAPOLLFD.{ fd = server.wake_up_socket, events = Socket.POLLIN };

    array_add(*server.wsapollfds, wsapollfd_wake_up);

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

    for server.clients_with_pending_reads {
        client := find_client(server, it);
        if client {
            client.is_in_pending_reads = false;
            parse_requests(server, it);
        }
    }

    array_reset_keeping_memory(*server.clients_with_pending_reads);

    if server.events.count > 0 && !peek {
        for server.clients_to_close_in_next_iteration array_add(*server.events, .{ type = .Client_Closed, client_closed = it });
        return false, server.events;
    }

    timeout := process_timeouts_and_get_next_timeout(server);
    if peek || server.events.count > 0 timeout = 0;

    number_of_events := Socket.WSAPoll(server.wsapollfds.data, xx server.wsapollfds.count, xx timeout);
    if number_of_events == Socket.SOCKET_ERROR return true, .[];

    ERROR_EVENTS :: Socket.POLLPRI | Socket.POLLHUP | Socket.POLLERR | Socket.POLLNVAL;

    for < server.wsapollfds {
        if it.fd == server.wake_up_socket {
            if it.revents & Socket.POLLIN {
                buffer: [64] u8;
                Socket.recvfrom(server.wake_up_socket, buffer.data, 64, 0, null, null);
            }

            continue;
        }

        if it.fd == server.listening_socket {
            if it.revents & Socket.POLLIN accept_clients(server);
            if it.revents & ERROR_EVENTS return true, .[];
            continue;
        }

        client_id := it.fd;

        if it.revents & ERROR_EVENTS {
            client := find_client(server, client_id);
            if client close(server, client);
            continue;
        }

        if it.revents & Socket.POLLOUT {
            closed := client_can_send(server, client_id);
            if closed continue;
        }

        if it.revents & Socket.POLLIN {
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
    listening_socket: Socket.Socket;

    clients:     Table(Socket.Socket, Http_Client);
    max_clients: int;

    next_client_timeout:     Apollo_Time;
    has_next_client_timeout: bool;

    clients_to_close_in_next_iteration:  [..] Socket.Socket;
    clients_with_pending_reads:          [..] Socket.Socket;

    events: [..] Http_Event;
    events.allocator = temp;

    timers: [..] Http_Timer;
    next_timer_id: u64 = 1;

    wsapollfds: [..] Socket.WSAPOLLFD;

    tls:     bool;
    ssl_ctx: *LibreSSL.SSL_CTX;

    wake_up_socket: Socket.Socket;
    wake_up_port:   u16;
}

#scope_module

add_to_queue :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    wsapollfd := Socket.WSAPOLLFD.{ fd = client.client_id, events = Socket.POLLIN };
    array_add(*server.wsapollfds, wsapollfd);

    return false;
}

notify_when_sendable :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    if client.is_notifying_when_sendable return false;

    for * server.wsapollfds {
        if it.fd == client.client_id {
            it.events = Socket.POLLIN | Socket.POLLOUT;
            break;
        }
    }

    client.is_notifying_when_sendable = true;

    return false;
}

do_not_notify_when_sendable :: (server: *Http_Server, client: *Http_Client) -> error: bool {
    if !client.is_notifying_when_sendable return false;

    for * server.wsapollfds {
        if it.fd == client.client_id {
            it.events = Socket.POLLIN;
            break;
        }
    }

    client.is_notifying_when_sendable = false;

    return false;
}