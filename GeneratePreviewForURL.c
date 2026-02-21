#include <CoreFoundation/CoreFoundation.h>
#include <CoreServices/CoreServices.h>
#include <QuickLook/QuickLook.h>

#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

OSStatus GeneratePreviewForURL(void *thisInterface,
                               QLPreviewRequestRef preview,
                               CFURLRef url,
                               CFStringRef contentTypeUTI,
                               CFDictionaryRef options);

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview);
OSStatus GenerateThumbnailForURL(void *thisInterface,
                                 QLThumbnailRequestRef thumbnail,
                                 CFURLRef url,
                                 CFStringRef contentTypeUTI,
                                 CFDictionaryRef options,
                                 CGSize maxSize);
void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail);

static bool get_file_path(CFURLRef url, char *buffer, size_t buffer_size) {
    return CFURLGetFileSystemRepresentation(url, true, (UInt8 *)buffer, buffer_size);
}

static bool get_script_path(char *buffer, size_t buffer_size) {
    Dl_info info;
    if (dladdr((const void *)GeneratePreviewForURL, &info) == 0 || info.dli_fname == NULL) {
        return false;
    }

    char binary_path[PATH_MAX];
    if (realpath(info.dli_fname, binary_path) == NULL) {
        return false;
    }

    char tmp1[PATH_MAX];
    strncpy(tmp1, binary_path, sizeof(tmp1) - 1);
    tmp1[sizeof(tmp1) - 1] = '\0';

    char *macos_dir = dirname(tmp1);
    if (macos_dir == NULL) {
        return false;
    }

    char tmp2[PATH_MAX];
    strncpy(tmp2, macos_dir, sizeof(tmp2) - 1);
    tmp2[sizeof(tmp2) - 1] = '\0';
    char *contents_dir = dirname(tmp2);
    if (contents_dir == NULL) {
        return false;
    }

    int written = snprintf(buffer, buffer_size, "%s/Resources/parquet_quicklook.py", contents_dir);
    return written > 0 && (size_t)written < buffer_size;
}

static char *run_renderer_script(const char *script_path, const char *input_path, size_t *output_len) {
    int pipe_fd[2];
    if (pipe(pipe_fd) != 0) {
        return NULL;
    }

    posix_spawn_file_actions_t file_actions;
    if (posix_spawn_file_actions_init(&file_actions) != 0) {
        close(pipe_fd[0]);
        close(pipe_fd[1]);
        return NULL;
    }

    (void)posix_spawn_file_actions_adddup2(&file_actions, pipe_fd[1], STDOUT_FILENO);
    (void)posix_spawn_file_actions_addclose(&file_actions, pipe_fd[0]);

    char *const argv[] = {
        "/usr/bin/python3",
        (char *)script_path,
        "--input",
        (char *)input_path,
        "--max-rows",
        "100",
        NULL
    };

    pid_t pid = 0;
    int spawn_status = posix_spawn(&pid, "/usr/bin/python3", &file_actions, NULL, argv, environ);
    (void)posix_spawn_file_actions_destroy(&file_actions);
    close(pipe_fd[1]);

    if (spawn_status != 0) {
        close(pipe_fd[0]);
        return NULL;
    }

    size_t capacity = 8192;
    size_t length = 0;
    char *buffer = (char *)malloc(capacity);
    if (buffer == NULL) {
        close(pipe_fd[0]);
        return NULL;
    }

    for (;;) {
        char chunk[4096];
        ssize_t n = read(pipe_fd[0], chunk, sizeof(chunk));
        if (n <= 0) {
            break;
        }
        if (length + (size_t)n + 1 > capacity) {
            size_t new_capacity = capacity * 2;
            while (new_capacity < length + (size_t)n + 1) {
                new_capacity *= 2;
            }
            char *new_buffer = (char *)realloc(buffer, new_capacity);
            if (new_buffer == NULL) {
                free(buffer);
                close(pipe_fd[0]);
                return NULL;
            }
            buffer = new_buffer;
            capacity = new_capacity;
        }
        memcpy(buffer + length, chunk, (size_t)n);
        length += (size_t)n;
    }
    close(pipe_fd[0]);

    int wait_status = 0;
    (void)waitpid(pid, &wait_status, 0);

    buffer[length] = '\0';
    if (output_len != NULL) {
        *output_len = length;
    }
    return buffer;
}

static void set_html_preview(QLPreviewRequestRef preview, const char *html, size_t html_len) {
    if (preview == NULL || html == NULL) {
        return;
    }

    CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8 *)html, (CFIndex)html_len);
    if (data == NULL) {
        return;
    }

    QLPreviewRequestSetDataRepresentation(preview, data, kUTTypeHTML, NULL);
    CFRelease(data);
}

OSStatus GeneratePreviewForURL(void *thisInterface,
                               QLPreviewRequestRef preview,
                               CFURLRef url,
                               CFStringRef contentTypeUTI,
                               CFDictionaryRef options) {
    (void)thisInterface;
    (void)contentTypeUTI;
    (void)options;

    if (QLPreviewRequestIsCancelled(preview)) {
        return noErr;
    }

    char file_path[PATH_MAX];
    if (!get_file_path(url, file_path, sizeof(file_path))) {
        const char *html = "<html><body><pre>Unable to resolve parquet file path.</pre></body></html>";
        set_html_preview(preview, html, strlen(html));
        return noErr;
    }

    char script_path[PATH_MAX];
    if (!get_script_path(script_path, sizeof(script_path))) {
        const char *html =
            "<html><body><pre>Unable to locate parquet renderer script in bundle.</pre></body></html>";
        set_html_preview(preview, html, strlen(html));
        return noErr;
    }

    size_t html_len = 0;
    char *html = run_renderer_script(script_path, file_path, &html_len);
    if (html == NULL || html_len == 0) {
        const char *fallback =
            "<html><body><pre>Parquet preview failed. Ensure python3 and pyarrow are installed.</pre></body></html>";
        set_html_preview(preview, fallback, strlen(fallback));
        free(html);
        return noErr;
    }

    set_html_preview(preview, html, html_len);
    free(html);
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview) {
    (void)thisInterface;
    (void)preview;
}

OSStatus GenerateThumbnailForURL(void *thisInterface,
                                 QLThumbnailRequestRef thumbnail,
                                 CFURLRef url,
                                 CFStringRef contentTypeUTI,
                                 CFDictionaryRef options,
                                 CGSize maxSize) {
    (void)thisInterface;
    (void)thumbnail;
    (void)url;
    (void)contentTypeUTI;
    (void)options;
    (void)maxSize;
    return noErr;
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail) {
    (void)thisInterface;
    (void)thumbnail;
}
