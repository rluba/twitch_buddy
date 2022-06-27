CREDENTIALS_FILENAME :: ".twitch_buddy_credentials";

main :: () {
    credentials_path := tprint("%/%", get_home_directory(), CREDENTIALS_FILENAME);
    credentials_string, success := read_entire_file(credentials_path);
    if !success {
        log_error("Couldn’t read Twitch credentials from \"%\"", credentials_path);
        exit(1);
    }

    found, username, password := split_from_left(credentials_string, #char " ");
    if !found {
        log_error("Credentails in \"%\" have an invalid format. Expected: <username> <password>", credentials_path);
        exit(1);
    }
    found, password = split_from_left(password, #char "\n");
    
    twitch: Twitch_Chat;
    init(*twitch, event_callback, verbose = true);
    success = connect(*twitch, username, password);
    if !success then exit(1);

    while true {
        log("Updating…");
        success = update(*twitch, 5000);
        if !success then exit(1);
    }
}

event_callback :: (event: Twitch_Event) {
    if event.type == {
        case;
            log("Got event: %", event);
    }
}

#import "Basic";
#import "File";
#import "String";
#import "System";
#import "twitch_irc";

