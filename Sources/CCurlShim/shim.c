#include "CCurlShim.h"

void apc_global_init(void) {
    curl_global_init(CURL_GLOBAL_DEFAULT);
}

CURLcode apc_setopt_long(CURL *handle, CURLoption option, long value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode apc_setopt_off(CURL *handle, CURLoption option, long long value) {
    return curl_easy_setopt(handle, option, (curl_off_t)value);
}

CURLcode apc_setopt_str(CURL *handle, CURLoption option, const char *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode apc_setopt_ptr(CURL *handle, CURLoption option, void *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode apc_setopt_data(CURL *handle, CURLoption option, const void *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode apc_setopt_slist(CURL *handle, CURLoption option, struct curl_slist *value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode apc_setopt_write_cb(CURL *handle, CURLoption option, apc_write_cb value) {
    return curl_easy_setopt(handle, option, value);
}

CURLcode apc_setopt_debug_cb(CURL *handle, apc_debug_cb value) {
    return curl_easy_setopt(handle, CURLOPT_DEBUGFUNCTION, value);
}

CURLcode apc_getinfo_long(CURL *handle, CURLINFO info, long *value) {
    return curl_easy_getinfo(handle, info, value);
}

CURLcode apc_getinfo_double(CURL *handle, CURLINFO info, double *value) {
    return curl_easy_getinfo(handle, info, value);
}

CURLcode apc_getinfo_str(CURL *handle, CURLINFO info, const char **value) {
    return curl_easy_getinfo(handle, info, value);
}
