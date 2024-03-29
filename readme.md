# Twitch Buddy

A simple Twitch chat bot programmed in Jai.

It uses [twitch_irc](https://github.com/rluba/twitch_irc) and [uniform](https://github.com/rluba/uniform), so make sure you clone this repository with submodules.

Compile via `jai -import_dir modules buddi.jai`.

## Credentials

Twitch Buddy expects a file ".twitch_buddy_credentials" in your home directory that contains the following

```
<username>
#<channel_name>
<client_id>
<client_secret> #Optional
<oauth_access_token>
<oauth_refresh_token> #Optional
```

## Getting an OAuth token

Using the Twitch CLI:

```
twitch token -u -s 'chat:read chat:edit channel:moderate whispers:read whispers:edit'
```
