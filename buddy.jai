CREDENTIALS_FILENAME :: ".twitch_buddy_credentials";
COMMANDS_PATH :: "config/commands.txt";
PATTERNS_PATH :: "config/patterns.txt";

PATTERN_COOLDOWN_SECONDS :: 5 * 60;

twitch: Twitch_Chat(Credentials);

UPTIME_CHECK_INTERVAL_SECONDS :: 5 * 60;
last_uptime_check: Apollo_Time;

stream_live: bool;
stream_start_time: Apollo_Time;

builtin_commands: Table(string, #type ());

commands: Table(string, string);
commands_texts: [..] string; // Just for freeing

Pattern_Response :: struct {
    original_pattern: string;
    expression: Regexp;
    response: string;
    last_match_time: Apollo_Time = APOLLO_TIME_INVALID;
}
patterns: [..] Pattern_Response;
patterns_texts: [..] string; // Just for freeing

Args :: struct {
    verbose: bool;
}

Credentials :: struct {
    username: string;
    channel: string;
    client_id: string;
    client_secret: string;
    access_token: string;
    refresh_token: string;
}

credentials_path: string;
credentials: Credentials;

main :: () {
    context.logger = buddy_logger;

    success, args := parse_arguments(Args);

    credentials_path = sprint("%/%", get_home_directory(), CREDENTIALS_FILENAME);
    credentials_file_content: string;
    credentials_file_content, success = read_entire_file(credentials_path);
    if !success {
        log_error("Couldn’t read Twitch credentials from \"%\"", credentials_path);
        exit(1);
    }

    found: bool;
    remainder := credentials_file_content;
    using credentials;
    found, username, remainder = split_from_left(remainder, #char "\n");
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
    
    watcher: File_Watcher(void);
    init(*watcher, on_file_changed, null);
    add_directories(*watcher, "config");

    update_uptime(streamer_name, *credentials, client_id);
    reload_commands();
    reload_patterns();

    init(*twitch, event_callback, *credentials, verbose = args.verbose);
    while true {
        process_changes(*watcher);

        password := tprint("oauth:%", credentials.access_token);
        connected := ensure_connected_to_server(username, password);
        if connected {
            success = update(*twitch, 5000);
            if !success {
                disconnect(*twitch);
            }
        } else {
            log_error("Could not connect to Twitch server. Will retry...");
        }

        if to_seconds(current_time_monotonic() - last_uptime_check) > UPTIME_CHECK_INTERVAL_SECONDS {
            update_uptime(streamer_name, *credentials, client_id);
        }

        reset_temporary_storage();
    }
}

ensure_connected_to_server :: (username: string, password: string) -> bool {
    if is_connected(*twitch) return true;

    success := connect(*twitch, username, password);
    return success;
}

on_file_changed :: (watcher: *File_Watcher(void), change: *File_Change, user_data: *void) {
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

event_callback :: (event: Twitch_Event, data: *Credentials) {
    if event.type == {
        case .GLOBALUSERSTATE;
            success := cmd_join(*twitch, data.channel);
            if !success {
                log_error("Couldn’t join channel %", data.channel);
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
                                break;
                            } else {
                                log("Not responding for pattern % due to cooldown (%s remaining)", it.original_pattern, PATTERN_COOLDOWN_SECONDS - to_seconds(now - it.last_match_time));
                            }
                        }
                    }
                }
            }
        case;
            log("TTV %: %", event.type, event.raw);
    }
}

respond :: (message: string, response: string) {
    log("Responding: %", response);
    success := cmd_privmsg(*twitch, credentials.channel, response);
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
    cmd_privmsg(*twitch, credentials.channel, message);
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
        cmd_privmsg(*twitch, credentials.channel, message);
    } else {
        cmd_privmsg(*twitch, credentials.channel, "This stream is not live.");
    }
}

reload_commands :: () {
    handler: Text_File_Handler;
    handler.do_version_number = false;
    handler.strip_comments_from_ends_of_lines = false;
    defer deinit(*handler);

    short_name := "Commands";
    start_file(*handler, short_name, COMMANDS_PATH, false);
    if !handler.failed {
        table_reset(*commands);
        for commands_texts {
            free(it);
        }
        array_reset_keeping_memory(*commands_texts);

        array_add(*commands_texts, handler.file_data_to_free);
        handler.file_data_to_free = "";
    }

    while true {
        command_part, response, end := consume_next_multi_line(*handler, *commands_texts);
        if end break;
        if !command_part continue;

        remainder := command_part;
        found := true;
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

    response, found_command := table_find(*commands, "!project");
    if found_command {
        print_color("\nCurrent project: %\n\n", response, color=.BLUE);
    } else {
        log("\nNo current project command (!project) found!\n");
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
        for patterns_texts {
            free(it);
        }
        array_reset_keeping_memory(*patterns_texts);

        array_add(*patterns_texts, handler.file_data_to_free);
        handler.file_data_to_free = "";
    }

    while true {
        pattern, response, end := consume_next_multi_line(*handler, *patterns_texts);
        if end break;
        if !pattern continue;

        expression, success := compile(pattern, parse_flags = ParseFlags.LikePerl | .FoldCase);
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

consume_next_line_supporting_escaped_comment_character :: (handler: *Text_File_Handler, strings_to_free: *[..] string) -> (line: string, found: bool) {
    while true {
        line, found := consume_next_line(handler);
        if !found return "", false;   // consume_next_line returns false for 'found' when we are done.

        start_index := 0;
        while true {
            comment_index := find_index_from_left(line, handler.comment_character, start_index);
            if comment_index == -1 break;

            if comment_index && line[comment_index - 1] == #char "\\" {
                // @Hack: This is quite a mess and memory-inefficient. But it will do for now.
                // Maybe we should fold this function into consume_next_multi_line?
                line = join(slice(line, 0, comment_index - 1), slice(line, comment_index, line.count - comment_index)); 
                array_add(strings_to_free, line);
                start_index = comment_index;
            } else {
                line.count = comment_index;
                break;
            }
        }
        if !line continue;

        return line, true;
    }
}

consume_next_multi_line :: (handler: *Text_File_Handler, strings_to_free: *[..] string) -> left_part: string, response: string, end: bool {
    line, found := consume_next_line_supporting_escaped_comment_character(handler, strings_to_free);
    if !found return "", "", true;   // consume_next_line returns false for 'found' when we are done.

    left_part, response := break_by_spaces(line);   // break_by_spaces gives us two strings, the one before whitespace, and the one after.
    if !response {
        error(handler, "Expected a space and the response after the command specifier.");
        return "", "", false;
    }

    if response[response.count-1] == #char "\\" {
        builder: String_Builder;
        response.count -= 1;
        append(*builder, response);
        continued := true;
        while continued {
            line, found := consume_next_line_supporting_escaped_comment_character(handler, strings_to_free);
            if !found {
                error(handler, "Expected a continued command line but reached the end of the file.");
                free_buffers(*builder);
                return "", "", false;
            }

            line = trim(line);
            if line[line.count - 1] == #char "\\" {
                continued = true;
                line.count -= 1;
            } else {
                continued = false;
            }
            append(*builder, " ");
            append(*builder, line);
        }

        response = builder_to_string(*builder);
        array_add(strings_to_free, response);
    }

    return left_part, response, false;
}

TWITCH_API_BASE_URL :: "https://api.twitch.tv/helix";

update_uptime :: (username: string, credentials: *Credentials, client_id: string) -> bool {
    success, was_auth_error := try_update_uptime(username, credentials.access_token, client_id);
    if !success {
        if was_auth_error {
            success = refresh_access_token(credentials);
            if success {
                save_credentials(credentials);
                success = try_update_uptime(username, credentials.access_token, client_id);
            }
        }
    }

    return success;
}

save_credentials :: (using credentials: *Credentials) -> bool {
    data := tprint("%\n%\n%\n%\n%\n%\n", username, credentials.channel, client_id, client_secret, access_token, refresh_token);
    success := write_entire_file(credentials_path, data);
    if !success {
        log_error("Couldn’t write credentials to %", credentials_path);
        return false;
    }

    return true;
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

    response: Refresh_Token_Response;
    {
        push_allocator(temp);
        headers := string.["Content-Type: application/x-www-form-urlencoded"];
        payload := tprint("client_id=%&client_secret=%&grant_type=refresh_token&refresh_token=%", credentials.client_id, credentials.client_secret, credentials.refresh_token);

        response_code, success, response_builder := http_request(.POST, "https://id.twitch.tv/oauth2/token", cast([] u8) payload, headers);
        response_string := builder_to_string(*response_builder);
        if !is_success_code(response_code) {
            log_error("Could not refresh access token: %\n%", response_code, response_string);
            return false;
        }

        
        success, response = json_parse_string(response_string, Refresh_Token_Response);
        if !success {
            log_error("Could not parse refresh token response:\n%", response_string);
            return false;
        }
    }

    log("Refreshed access token");
    // Copy after temp allocator has been popped, or we’ll copy into temp and then lose that data!
    credentials.access_token = copy_string(response.access_token);
    if response.refresh_token {
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
            log("% is offline", username);
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

buddy_logger :: (message: string, data: *void, info: Log_Info) {
    if !message then return;

    to_standard_error := (info.common_flags & .ERROR) != 0;

    if (message && message != "\n") {
        now := current_time_consensus();
        cal := to_calendar(now, .LOCAL);
        fi2 :: #bake_arguments formatInt(minimum_digits = 2);
        date_string := tprint("%-% %:%: ", fi2(cal.month_starting_at_0 + 1), fi2(cal.day_of_month_starting_at_0 + 1), fi2(cal.hour), fi2(cal.minute));
        with_console_color(.HI_BLACK, to_standard_error = to_standard_error, code = #code {
            write_string(date_string, to_standard_error = to_standard_error);
        });
    }

    color := ifx to_standard_error then Console_Color.RED else Console_Color.BLACK;
    with_console_color(color, to_standard_error = to_standard_error, code = #code {
        if message[message.count-1] != #char "\n" {
            write_strings(message, "\n", to_standard_error = to_standard_error);
        } else {
            write_string(message, to_standard_error = to_standard_error);
        }
    });
}


#load "http_client.jai";

#import "Basic";
#import "Print_Color";
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
