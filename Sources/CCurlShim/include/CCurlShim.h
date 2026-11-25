#ifndef CCURL_SHIM_H
#define CCURL_SHIM_H

#include <curl/curl.h>

// curl_easy_setopt and curl_easy_getinfo are variadic, so Swift cannot call
// them. These wrappers give each argument type a fixed signature.

typedef size_t (*apc_write_cb)(char *ptr, size_t size, size_t nmemb, void *userdata);
typedef int (*apc_debug_cb)(CURL *handle, curl_infotype type, char *data, size_t size, void *userdata);

void apc_global_init(void);

CURLcode apc_setopt_long(CURL *handle, CURLoption option, long value);
CURLcode apc_setopt_off(CURL *handle, CURLoption option, long long value);
CURLcode apc_setopt_str(CURL *handle, CURLoption option, const char *value);
CURLcode apc_setopt_ptr(CURL *handle, CURLoption option, void *value);
CURLcode apc_setopt_data(CURL *handle, CURLoption option, const void *value);
CURLcode apc_setopt_slist(CURL *handle, CURLoption option, struct curl_slist *value);
CURLcode apc_setopt_write_cb(CURL *handle, CURLoption option, apc_write_cb value);
CURLcode apc_setopt_debug_cb(CURL *handle, apc_debug_cb value);

CURLcode apc_getinfo_long(CURL *handle, CURLINFO info, long *value);
CURLcode apc_getinfo_double(CURL *handle, CURLINFO info, double *value);
CURLcode apc_getinfo_str(CURL *handle, CURLINFO info, const char **value);

#endif
