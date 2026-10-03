#include "CGitShim.h"
#include <git2.h>

int lsg_set_ssl_cert_locations(const char *file, const char *path)
{
	return git_libgit2_opts(GIT_OPT_SET_SSL_CERT_LOCATIONS, file, path);
}

int lsg_set_server_timeouts(int connect_timeout_ms, int io_timeout_ms)
{
	int error = git_libgit2_opts(GIT_OPT_SET_SERVER_CONNECT_TIMEOUT, connect_timeout_ms);
	if (error < 0)
		return error;
	return git_libgit2_opts(GIT_OPT_SET_SERVER_TIMEOUT, io_timeout_ms);
}

int lsg_set_owner_validation(int enabled)
{
	return git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, enabled);
}

int lsg_set_user_agent(const char *user_agent)
{
	return git_libgit2_opts(GIT_OPT_SET_USER_AGENT, user_agent);
}

int lsg_set_search_path(int level, const char *path)
{
	return git_libgit2_opts(GIT_OPT_SET_SEARCH_PATH, level, path);
}

int lsg_set_mwindow_mapped_limit(size_t bytes)
{
	return git_libgit2_opts(GIT_OPT_SET_MWINDOW_MAPPED_LIMIT, bytes);
}

int lsg_set_mwindow_file_limit(size_t files)
{
	return git_libgit2_opts(GIT_OPT_SET_MWINDOW_FILE_LIMIT, files);
}

int lsg_set_strict_object_creation(int enabled)
{
	return git_libgit2_opts(GIT_OPT_ENABLE_STRICT_OBJECT_CREATION, enabled);
}
