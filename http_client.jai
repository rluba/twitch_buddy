Http_Method :: enum {
	GET :: 0;
	POST :: 1;
	PUT :: 2;
}

http_get :: #bake_arguments http_request(method = Http_Method.GET, data = u8.[]);

http_request :: (method: Http_Method, url: string, data: [] u8, headers: [] string = .[], auth := "", verify_peer := true, $save_response := true) -> response_code: int, success: bool, response: String_Builder {
	response_builder: String_Builder;
	curl := curl_easy_init();
	if curl == null {
		log_error("curl initialization failed.");
		return 0, false, response_builder;
	}
	defer curl_easy_cleanup(curl);

	curl_easy_setopt(curl, .URL, temp_c_string(url));
	if !verify_peer {
		curl_easy_setopt(curl, .SSL_VERIFYPEER, 0);
	}

	success := set_auth(curl, auth);
	if !success {
		return 0, false, response_builder;
	}

	#if save_response {
		curl_easy_setopt(curl, .WRITEFUNCTION, write_to_builder);
		curl_easy_setopt(curl, .WRITEDATA, *response_builder);
	} else {
		curl_easy_setopt(curl, .WRITEFUNCTION, dont_write);
		curl_easy_setopt(curl, .WRITEDATA, null);
	}

	data_copy := data;

	if method == {
		case .POST;
			curl_easy_setopt(curl, .POST, 1);
			curl_easy_setopt(curl, .POSTFIELDSIZE, data.count);
			curl_easy_setopt(curl, .POSTFIELDS, data.data);
		case .PUT;
			curl_easy_setopt(curl, .UPLOAD, 1);
			curl_easy_setopt(curl, .READFUNCTION, read_array);
			curl_easy_setopt(curl, .READDATA, *data_copy);
			curl_easy_setopt(curl, .INFILESIZE, data.count);
	}

	header_list : *curl_slist;
	defer curl_slist_free_all(header_list);
	for headers	{
		header_list = curl_slist_append(header_list, temp_c_string(it));
	}
	curl_easy_setopt(curl, .HTTPHEADER, header_list);

	res := curl_easy_perform(curl);
	if res != .OK {
		log_error("request failed: %", to_string(curl_easy_strerror(res)));
		return 0, false, response_builder;
	}

	response_code: s64;
	curl_easy_getinfo(curl, .RESPONSE_CODE, *response_code);
	return response_code, true, response_builder;
}

set_auth :: (curl: *CURL, auth: string) -> bool {
	if auth {
		separator := find_index_from_left(auth, #char ":");
		if separator == -1 {
			log_error("Authentication information must be in format <username:password>");
			return false;
		}
		username := slice(auth, 0, separator);
		password := slice(auth, separator + 1, auth.count - separator - 1);
		curl_easy_setopt(curl, .USERNAME, temp_c_string(username));
		curl_easy_setopt(curl, .PASSWORD, temp_c_string(password));
	}
	return true;
}

is_success_code :: (code: int) -> bool {
	return code >= 200 && code <= 299;
}

write_to_builder :: (ptr: *u8, size: size_t, nmemb: size_t, userdata: *void) -> size_t #c_call {
    new_context: Context;
    new_context.logger = buddy_logger;
    push_context new_context {
		builder := cast(*String_Builder) userdata;
		append(builder, ptr, cast(s64) (size * nmemb));
		return size * nmemb;
	}
}

dont_write :: (ptr: *u8, size: size_t, nmemb: size_t, userdata: *void) -> size_t #c_call {
	return size * nmemb;
}

read_array :: (ptr: *u8, size: size_t, nmemb: size_t, userdata: *void) -> size_t #c_call {
    new_context: Context;
    new_context.logger = buddy_logger;
    push_context new_context {
		data := cast(*[] u8) userdata;
		amount := (size * nmemb);
		if cast(u64) data.count < amount {
			amount = cast(u64) data.count;
		}
		memcpy(ptr, data.data, cast(s64) amount);
		data.data += cast(s64) amount;
		data.count -= cast(s64) amount;
		return amount;
	}
}

#scope_file

#import "Basic";
#import "String";
#import "Curl";

#import "POSIX";
