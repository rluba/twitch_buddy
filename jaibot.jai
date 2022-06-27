CHANNEL :: "#raphael_luba";
CREDENTIALS_FILENAME :: ".twitch_buddy_credentials";
COMMANDS_PATH :: "config/commands.txt";

twitch: Twitch_Chat;

commands: Table(string, string);
commands_text: string; // Just for freeing

main :: () {
    #if OS == .MACOS {
        init_macos();
    }
    credentials_path := tprint("%/%", get_home_directory(), CREDENTIALS_FILENAME);
    credentials_string, success := read_entire_file(credentials_path);
    if !success {
        log_error("Couldn’t read Twitch credentials from \"%\"", credentials_path);
        exit(1);
    }

    watcher: File_Watcher;
    init(*watcher, on_file_changed);
    add_directories(*watcher, "config");

    reload_commands();

    found, username, password := split_from_left(credentials_string, #char " ");
    if !found {
        log_error("Credentails in \"%\" have an invalid format. Expected: <username> <password>", credentials_path);
        exit(1);
    }
    found, password = split_from_left(password, #char "\n");
    
    init(*twitch, event_callback, verbose = true);
    success = connect(*twitch, username, password);
    if !success then exit(1);

    while true {
        log("Updating…");
        process_changes(*watcher);

        success = update(*twitch, 5000);
        if !success then exit(1);

        reset_temporary_storage();
    }
}

on_file_changed :: (watcher: *File_Watcher, change: *File_Change) {
    // filename := path_get_filename(change.full_path);
    if ends_with(change.full_path, COMMANDS_PATH) {
        log("Reloading commands…");
        reload_commands();
    } else {
        log("Unknown file changed: %", change.full_path);
    }
}

event_callback :: (event: Twitch_Event) {
    if event.type == {
        case .GLOBALUSERSTATE;
            success := cmd_join(*twitch, CHANNEL);
            if !success {
                log_error("Couldn’t join channel %", CHANNEL);
                exit(1);
            }
        case .PRIVMSG;
            log("Chat message: %", event.parameter);
            if event.parameter == {
                case "!commands";
                    send_command_list();
                case;
                    response, found_command := table_find(*commands, event.parameter);
                    if found_command {
                        success := cmd_privmsg(*twitch, CHANNEL, response);
                        if !success {
                            log_error("Couldn’t respond to command \"%\"", event.parameter);
                        }
                    }
            }
        case;
            log("Got event: %", event);
    }
}

send_command_list :: () {
    push_allocator(temp);
    sorted_commands: [..] string;
    array_reserve(*sorted_commands, commands.count);
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
    cmd_privmsg(*twitch, CHANNEL, message);
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

        command, response := break_by_spaces(line);   // break_by_spaces gives us two strings, the one before whitespace, and the one after.
        if !response {
            error(handler, "Expected a space and the response after the command specifier.");
            continue;
        }

        table_add(*commands, command, response);
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

#import "Basic";
#import "File";
#import "String";
#import "System";
#import "twitch_irc";
#import "File_Watcher";
#import "Text_File_Handler";
#import "Hash_Table";
#if OS == .MACOS {
    #import "macos";
}
#import "IntroSort";
