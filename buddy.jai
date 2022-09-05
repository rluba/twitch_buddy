CREDENTIALS_FILENAME :: ".twitch_buddy_credentials";
COMMANDS_PATH :: "config/commands.txt";
PATTERNS_PATH :: "config/patterns.txt";

PATTERN_COOLDOWN_SECONDS :: 5 * 60;

twitch: Twitch_Chat;

channel: string;

UPTIME_CHECK_INTERVAL_SECONDS :: 5 * 60;
last_uptime_check: Apollo_Time;

stream_live: bool;
stream_start_time: Apollo_Time;

builtin_commands: Table(string, #type ());

commands: Table(string, string);
commands_text: string; // Just for freeing

Pattern_Response :: struct {
    original_pattern: string;
    expression: Regexp;
    response: string;
    last_match_time: Apollo_Time = APOLLO_TIME_INVALID;
}
patterns: [..] Pattern_Response;
patterns_text: string; // Just for freeing

Args :: struct {
    verbose: bool;
}

Credentials :: struct {
    client_id: string;
    client_secret: string;
    access_token: string;
    refresh_token: string;
}

main :: () {
    #if OS == .MACOS {
        init_macos();
    }

    success, args := parse_arguments(Args);

    credentials_path := tprint("%/%", get_home_directory(), CREDENTIALS_FILENAME);
    credentials_file_content: string;
    credentials_file_content, success = read_entire_file(credentials_path);
    if !success {
        log_error("Couldn’t read Twitch credentials from \"%\"", credentials_path);
        exit(1);
    }

    using credentials: Credentials;
    found, username, remainder := split_from_left(credentials_file_content, #char "\n");
    found, channel, remainder = split_from_left(remainder, #char "\n");
    found, client_id, remainder = split_from_left(remainder, #char "\n");
    found, client_secret, remainder = split_from_left(remainder, #char "\n");
    found, access_token, remainder = split_from_left(remainder, #char "\n");
    found, refresh_token, remainder = split_from_left(remainder, #char "\n");

    channel = trim(channel, " \t\r\n");
    client_id = trim(client_id, " \t\r\n");
    if !begins_with(channel, "#") {
        log_error("Invalid credentials. Expected channel name to begin with \"#\".");
        exit(1);
    }
    if !client_id {
        log_error("Invalid credentials. Missing client ID.");
        exit(1);
    }

    if !username || !access_token {
        log_error("Credentials in \"%\" have an invalid format. See readme.md for details.", credentials_path);
        exit(1);
    }

    streamer_name := slice(channel, 1, channel.count - 1);

    table_add(*builtin_commands, "!commands", #bake_arguments send_command_list(used_command = "!commands"));
    table_add(*builtin_commands, "!help", #bake_arguments send_command_list(used_command = "!help"));
    table_add(*builtin_commands, "!uptime", send_uptime);
    
    watcher: File_Watcher;
    init(*watcher, on_file_changed);
    add_directories(*watcher, "config");

    reload_commands();
    reload_patterns();
    update_uptime(streamer_name, *credentials, client_id);

    init(*twitch, event_callback, verbose = args.verbose);
    password := tprint("oauth:%", credentials.access_token);
    success = connect(*twitch, username, password);
    if !success {
        log_error("Could not connect to Twitch");
        exit(1);
    }

    while true {
        process_changes(*watcher);

        success = update(*twitch, 5000);
        if !success then exit(1);

        if to_seconds(current_time_monotonic() - last_uptime_check) > UPTIME_CHECK_INTERVAL_SECONDS {
            update_uptime(streamer_name, *credentials, client_id);
        }

        reset_temporary_storage();
    }
}

on_file_changed :: (watcher: *File_Watcher, change: *File_Change) {
    // filename := path_get_filename(change.full_path);
    if ends_with(change.full_path, COMMANDS_PATH) {
        log("Reloading commands…");
        reload_commands();
    } else if ends_with(change.full_path, PATTERNS_PATH) {
        log("Reloading patterns…");
        reload_patterns();
    } else {
        log("Unknown file cgthanged: %", change.full_path);
    }
}

event_callback :: (event: Twitch_Event) {
    if event.type == {
        case .GLOBALUSERSTATE;
            success := cmd_join(*twitch, channel);
            if !success {
                log_error("Couldn’t join channel %", channel);
                exit(1);
            }
        case .PRIVMSG;
            user := get_tag_value(event.tags, "display-name");
            message := event.parameter;
            log("Chat message from %: %", user, message);
            if user == twitch.login.nickname {
                // Don't respond to our own messages
                return;
            }

            response_fn, found_builtin_command := table_find(*builtin_commands, message);
            if found_builtin_command {
                response_fn();
            } else {
                response, found_command := table_find(*commands, message);
                if found_command {
                    respond(message, response);
                } else {
                    push_allocator(temp);
                    now := current_time_monotonic();
                    for * patterns {
                        matched := match(message, it.expression);
                        if matched {
                            if it.last_match_time == APOLLO_TIME_INVALID || (to_seconds(now - it.last_match_time) > PATTERN_COOLDOWN_SECONDS) {
                                respond(message, it.response);
                                it.last_match_time = now;
                            } else {
                                log("Not responding for pattern % due to cooldown (%s remaining)", it.original_pattern, PATTERN_COOLDOWN_SECONDS - to_seconds(now - it.last_match_time));
                            }
                        }
                    }
                }
            }
        case;
            log("Received %: %", event.type, event.raw);
    }
}

respond :: (message: string, response: string) {
    log("Responding: %", response);
    success := cmd_privmsg(*twitch, channel, response);
    if !success {
        log_error("Couldn’t send response to \"%\"", message);
    }
}

send_command_list :: (used_command: string) {
    push_allocator(temp);
    sorted_commands: [..] string;
    array_reserve(*sorted_commands, builtin_commands.count + commands.count);

    for builtin_commands {
        if it_index == used_command then continue;
        array_add(*sorted_commands, it_index);
    }
    for commands {
        array_add(*sorted_commands, it_index);
    }

    intro_sort(sorted_commands, compare);

    builder: String_Builder;
    append(*builder, "Available commands:");
    for sorted_commands {
        append(*builder, " ");
        append(*builder, it);
    }
    message := builder_to_string(*builder, temp);
    cmd_privmsg(*twitch, channel, message);
}

send_uptime :: () {
    if stream_live {
        uptime_seconds := to_seconds(current_time_consensus() - stream_start_time);
        uptime_total_minutes := uptime_seconds / 60;
        uptime_hours   := uptime_total_minutes / 60;
        uptime_minutes := uptime_total_minutes % 60;

        hours_label := ifx uptime_hours == 1 then "hour" else "hours";
        minutes_label := ifx uptime_minutes == 1 then "minute" else "minutes";

        message := tprint("This stream has been live for % % % %.", uptime_hours, hours_label, uptime_minutes, minutes_label);
        cmd_privmsg(*twitch, channel, message);
    } else {
        cmd_privmsg(*twitch, channel, "This stream is not live.");
    }
}

reload_commands :: () {
    handler: Text_File_Handler;
    handler.do_version_number = false;
    defer deinit(*handler);

    short_name := "Commands";
    start_file(*handler, short_name, COMMANDS_PATH, false);
    if !handler.failed {
        table_reset(*commands);
        free(commands_text);

        commands_text = handler.file_data_to_free;
        handler.file_data_to_free = "";
    }

    while true {
        line, found := consume_next_line(*handler);
        if !found break;   // consume_next_line returns false for 'found' when we are done.

        command_part, response := break_by_spaces(line);   // break_by_spaces gives us two strings, the one before whitespace, and the one after.
        if !response {
            error(handler, "Expected a space and the response after the command specifier.");
            continue;
        }

        remainder := command_part;
        while found {
            command: string;
            found, command, remainder = split_from_left(remainder, #char ",");
            table_add(*commands, command, response);
        }
    }

    if handler.failed {
        log_error("Couldn’t read commands from \"%\"", COMMANDS_PATH);
        exit(1);
    }

    log("Loaded % commands:", commands.count);
    for commands {
        log("\t%", it_index);
    }
}

reload_patterns :: () {
    handler: Text_File_Handler;
    handler.do_version_number = false;
    defer deinit(*handler);

    short_name := "Patterns";
    start_file(*handler, short_name, PATTERNS_PATH, false);
    if !handler.failed {
        for patterns {
            uninit(*it.expression);
        }
        array_reset(*patterns);
        free(patterns_text);

        patterns_text = handler.file_data_to_free;
        handler.file_data_to_free = "";
    }

    while true {
        line, found := consume_next_line(*handler);
        if !found break;   // consume_next_line returns false for 'found' when we are done.

        pattern, response := break_by_spaces(line);   // break_by_spaces gives us two strings, the one before whitespace, and the one after.
        if !response {
            error(handler, "Expected a space and the response after the pattern.");
            continue;
        }

        expression, success := compile(pattern);
        if !success {
            error(handler, "Could not compile regular expression");
            continue;
        }

        result: Pattern_Response;
        result.original_pattern = pattern;
        result.expression = expression;
        result.response = response;
        array_add(*patterns, result);
    }

    if handler.failed {
        log_error("Couldn’t read patterns from \"%\"", PATTERNS_PATH);
        exit(1);
    }

    log("Loaded % patterns", patterns.count);
}

TWITCH_API_BASE_URL :: "https://api.twitch.tv/helix";

update_uptime :: (username: string, credentials: *Credentials, client_id: string) -> bool {
    success, was_auth_error := try_update_uptime(username, credentials.access_token, client_id);
    if !success {
        if was_auth_error {
            success = refresh_access_token(credentials);
            if success {
                success = try_update_uptime(username, credentials.access_token, client_id);
            }
        }
    }

    return success;
}

Refresh_Token_Response :: struct {
    access_token: string;
    refresh_token: string;
    scope: [] string;
    token_type: string;
}

refresh_access_token :: (credentials: *Credentials) -> bool {
    if !credentials.client_secret {
        log_error("Cannot refresh access token: No client secret configured.");
        return false;
    }
    if !credentials.refresh_token {
        log_error("Cannot refresh access token: No refresh token configured.");
        return false;
    }

    push_allocator(temp);
    headers := string.["Content-Type: application/x-www-form-urlencoded"];
    payload := tprint("client_id=%&client_secret=%&grant_type=refresh_token&refresh_token=%", credentials.client_id, credentials.client_secret, credentials.refresh_token);

    response_code, success, response_builder := http_request(.POST, "https://id.twitch.tv/oauth2/token", cast([] u8) payload, headers);
    response_string := builder_to_string(*response_builder);
    if !is_success_code(response_code) {
        log_error("Could not refresh access token: %\n%", response_code, response_string);
        return false;
    }

    
    {
        success, response := json_parse_string(response_string, Refresh_Token_Response);
        if !success {
            log_error("Could not parse refresh token response:\n%", response_string);
            return false;
        }

        credentials.access_token = copy_string(response.access_token);
        credentials.refresh_token = copy_string(response.refresh_token);
    }
    return true;
}

try_update_uptime :: (username: string, access_token: string, client_id: string) -> success: bool, was_auth_error := false {
    last_uptime_check = current_time_monotonic();

    streams_url := tprint("%/streams?user_login=%", TWITCH_API_BASE_URL, escape_url_param(username));
    headers: [2] string;
    headers[0] = tprint("Authorization: Bearer %", access_token);
    headers[1] = tprint("Client-Id: %", client_id);

    response_code, success, response_builder := http_get(streams_url, headers);
    response := builder_to_string(*response_builder, temp);
    if !is_success_code(response_code) {
        if response_code == 401 {
            return false, true;
        }

        log_error("Could not fetch stream details for %: Code %\n%", username, response_code, response);
        return false;
    }


    {
        success, result := json_parse_string(response, Twitch_List(Stream_Info));
        if !success {
            log_error("Couldn’t parse stream details response");
            return false;
        }

        if result.data.count == 1 {
            info := result.data[0];
            log("Stream info: %", info);

            matched, captures := match(info.started_at, "^(\\d{4})-(\\d{2})-(\\d{2})T(\\d{2}):(\\d{2}):(\\d{2})Z$");
            defer array_free(captures);
            if !matched {
                log_error("Could not parse stream start time \"%\"", info.started_at);
                return false;
            }

            calendar: Calendar_Time;
            calendar.year = xx to_integer(captures[1]);
            calendar.month_starting_at_0 = xx (to_integer(captures[2]) - 1);
            calendar.day_of_month_starting_at_0 = xx (to_integer(captures[3]) - 1);
            calendar.hour = xx to_integer(captures[4]);
            calendar.minute = xx to_integer(captures[5]);
            calendar.second = xx to_integer(captures[6]);
            calendar.time_zone = .UTC;

            stream_live = true;
            stream_start_time = calendar_to_apollo(calendar);
        } else {
            stream_live = false;
        }
    }

    return true;
}

Twitch_List :: struct (T: Type) {
    data: [] T;
}

Stream_Info :: struct {
    started_at: string;
    title: string;
    type: string;
}

escape_url_param :: (param: string) -> string {
    // @ToDo
    return param;
}

#load "http_client.jai";

#import "Basic";
#import "Command_Line";
#import "File";
#import "File_Watcher";
#import "Hash_Table";
#import "IntroSort";
#import "jason";
#import "String";
#import "System";
#import "Text_File_Handler";
#import "twitch_irc";
#import "uniform";
#if OS == .MACOS {
    #import "macos";
}
