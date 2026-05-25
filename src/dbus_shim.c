#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <systemd/sd-bus.h>
#include <poll.h>
#include <time.h>
#include <errno.h>

#define BUS_NAME "org.freedesktop.UPower.PowerProfiles"
#define OBJECT_PATH "/org/freedesktop/UPower/PowerProfiles"
#define INTERFACE "org.freedesktop.UPower.PowerProfiles"
#define VERSION "0.1.0"

extern const char *ppd_get_active_profile(void *ctx);
extern int ppd_set_active_profile_id(void *ctx, int profile_id);
extern int ppd_poll_fd(void *ctx);
extern int ppd_check_external_update(void *ctx);
extern int ppd_profile_id_from_name(const char *name);
static sd_bus *global_bus = NULL;

enum {
    PROFILE_POWER_SAVER = 0,
    PROFILE_BALANCED = 1,
    PROFILE_PERFORMANCE = 2,
};

static int append_empty_aa_sv(sd_bus_message *reply) {
    int r = sd_bus_message_open_container(reply, 'a', "a{sv}");
    if (r < 0) return r;
    return sd_bus_message_close_container(reply);
}

static int append_empty_as(sd_bus_message *reply) {
    int r = sd_bus_message_open_container(reply, 'a', "s");
    if (r < 0) return r;
    return sd_bus_message_close_container(reply);
}

static int append_dict_string(sd_bus_message *reply, const char *key, const char *value) {
    int r = sd_bus_message_open_container(reply, 'e', "sv");
    if (r < 0) return r;
    r = sd_bus_message_append(reply, "s", key);
    if (r < 0) return r;
    r = sd_bus_message_open_container(reply, 'v', "s");
    if (r < 0) return r;
    r = sd_bus_message_append(reply, "s", value);
    if (r < 0) return r;
    r = sd_bus_message_close_container(reply);
    if (r < 0) return r;
    return sd_bus_message_close_container(reply);
}

static int append_profile(sd_bus_message *reply, const char *name) {
    int r = sd_bus_message_open_container(reply, 'a', "{sv}");
    if (r < 0) return r;
    r = append_dict_string(reply, "Profile", name);
    if (r < 0) return r;
    r = append_dict_string(reply, "Driver", "platform_profile");
    if (r < 0) return r;
    return sd_bus_message_close_container(reply);
}

static int get_active_profile(sd_bus *bus, const char *path, const char *interface,
                              const char *property, sd_bus_message *reply,
                              void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)reterr_error;
    return sd_bus_message_append(reply, "s", ppd_get_active_profile(userdata));
}

static int set_active_profile(sd_bus *bus, const char *path, const char *interface,
                              const char *property, sd_bus_message *value,
                              void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    if (strcmp(path, OBJECT_PATH) != 0)
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_INVALID_ARGS, "unsupported object path");
    if (strcmp(interface, INTERFACE) != 0)
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_INVALID_ARGS, "unsupported interface");
    if (strcmp(property, "ActiveProfile") != 0)
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_PROPERTY_READ_ONLY, "unsupported property");

    const char *profile = NULL;
    int r = sd_bus_message_read(value, "s", &profile);
    if (r < 0) return r;

    int profile_id = ppd_profile_id_from_name(profile);
    if (profile_id < 0)
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_INVALID_ARGS,
                                 "unsupported profile '%s'", profile);

    switch (ppd_set_active_profile_id(userdata, profile_id)) {
    case 0:
        return 1;
    case 1:
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_NOT_SUPPORTED,
                                 "platform_profile sysfs is unavailable");
    case 2:
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_INVALID_ARGS,
                                 "unsupported profile '%s'", profile);
    case 3:
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_ACCESS_DENIED,
                                 "permission denied writing platform_profile");
    default:
        return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_FAILED,
                                 "failed to write platform_profile");
    }
}

static int get_profiles(sd_bus *bus, const char *path, const char *interface,
                        const char *property, sd_bus_message *reply,
                        void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)reterr_error;
    (void)userdata;

    int r = sd_bus_message_open_container(reply, 'a', "a{sv}");
    if (r < 0) return r;
    r = append_profile(reply, "power-saver");
    if (r < 0) return r;
    r = append_profile(reply, "balanced");
    if (r < 0) return r;
    r = append_profile(reply, "performance");
    if (r < 0) return r;
    return sd_bus_message_close_container(reply);
}

static int get_empty_string(sd_bus *bus, const char *path, const char *interface,
                            const char *property, sd_bus_message *reply,
                            void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)userdata;
    (void)reterr_error;
    return sd_bus_message_append(reply, "s", "");
}

static int get_version(sd_bus *bus, const char *path, const char *interface,
                       const char *property, sd_bus_message *reply,
                       void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)userdata;
    (void)reterr_error;
    return sd_bus_message_append(reply, "s", VERSION);
}

static int get_false(sd_bus *bus, const char *path, const char *interface,
                     const char *property, sd_bus_message *reply,
                     void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)userdata;
    (void)reterr_error;
    return sd_bus_message_append(reply, "b", 0);
}

static int set_battery_aware(sd_bus *bus, const char *path, const char *interface,
                             const char *property, sd_bus_message *value,
                             void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)userdata;

    int enabled = 0;
    int r = sd_bus_message_read(value, "b", &enabled);
    if (r < 0) return r;
    if (!enabled) return 1;
    return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_NOT_SUPPORTED,
                             "BatteryAware policy is intentionally not implemented");
}

static int get_actions(sd_bus *bus, const char *path, const char *interface,
                       const char *property, sd_bus_message *reply,
                       void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)userdata;
    (void)reterr_error;
    return append_empty_as(reply);
}

static int get_empty_dict_array(sd_bus *bus, const char *path, const char *interface,
                                const char *property, sd_bus_message *reply,
                                void *userdata, sd_bus_error *reterr_error) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)userdata;
    (void)reterr_error;
    return append_empty_aa_sv(reply);
}

static int hold_profile(sd_bus_message *m, void *userdata, sd_bus_error *reterr_error) {
    (void)m;
    (void)userdata;
    return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_NOT_SUPPORTED,
                             "profile holds are intentionally not implemented");
}

static int release_profile(sd_bus_message *m, void *userdata, sd_bus_error *reterr_error) {
    (void)m;
    (void)userdata;
    return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_NOT_SUPPORTED,
                             "profile holds are intentionally not implemented");
}

static int set_action_enabled(sd_bus_message *m, void *userdata, sd_bus_error *reterr_error) {
    (void)m;
    (void)userdata;
    return sd_bus_error_setf(reterr_error, SD_BUS_ERROR_INVALID_ARGS,
                             "actions are intentionally not implemented");
}

static const sd_bus_vtable power_profiles_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_WRITABLE_PROPERTY("ActiveProfile", "s", get_active_profile, set_active_profile, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("PerformanceInhibited", "s", get_empty_string, 0, 0),
    SD_BUS_PROPERTY("PerformanceDegraded", "s", get_empty_string, 0, 0),
    SD_BUS_PROPERTY("Profiles", "aa{sv}", get_profiles, 0, 0),
    SD_BUS_PROPERTY("Actions", "as", get_actions, 0, 0),
    SD_BUS_PROPERTY("ActionsInfo", "aa{sv}", get_empty_dict_array, 0, 0),
    SD_BUS_PROPERTY("ActiveProfileHolds", "aa{sv}", get_empty_dict_array, 0, 0),
    SD_BUS_PROPERTY("Version", "s", get_version, 0, 0),
    SD_BUS_WRITABLE_PROPERTY("BatteryAware", "b", get_false, set_battery_aware, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_METHOD("HoldProfile", "sss", "u", hold_profile, 0),
    SD_BUS_METHOD("ReleaseProfile", "u", "", release_profile, 0),
    SD_BUS_METHOD("SetActionEnabled", "sb", "", set_action_enabled, 0),
    SD_BUS_VTABLE_END,
};

void ppd_emit_active_profile_changed(void) {
    if (global_bus)
        (void)sd_bus_emit_properties_changed(global_bus, OBJECT_PATH, INTERFACE, "ActiveProfile", NULL);
}

int ppd_bus_run(void *state) {
    sd_bus *bus = NULL;
    sd_bus_slot *slot = NULL;

    int r = sd_bus_open_system(&bus);
    if (r < 0) {
        fprintf(stderr, "failed to connect to system bus: %s\n", strerror(-r));
        return r;
    }

    global_bus = bus;

    r = sd_bus_add_object_vtable(bus, &slot, OBJECT_PATH, INTERFACE, power_profiles_vtable, state);
    if (r < 0) {
        fprintf(stderr, "failed to install D-Bus object: %s\n", strerror(-r));
        goto finish;
    }

    r = sd_bus_request_name(bus, BUS_NAME, 0);
    if (r < 0) {
        fprintf(stderr, "failed to acquire bus name: %s\n", strerror(-r));
        goto finish;
    }

    for (;;) {
        r = sd_bus_process(bus, NULL);
        if (r < 0) {
            fprintf(stderr, "failed to process bus: %s\n", strerror(-r));
            goto finish;
        }
        if (r > 0)
            continue;

        int sysfs_fd = ppd_poll_fd(state);

        struct pollfd fds[2];
        int nfds = 1;

        fds[0].fd = sd_bus_get_fd(bus);
        fds[0].events = sd_bus_get_events(bus);
        fds[0].revents = 0;

        if (sysfs_fd >= 0) {
            fds[1].fd = sysfs_fd;
            fds[1].events = POLLPRI | POLLERR;
            fds[1].revents = 0;
            nfds = 2;
        }

        uint64_t timeout_usec;
        r = sd_bus_get_timeout(bus, &timeout_usec);
        if (r < 0) {
            fprintf(stderr, "failed to get bus timeout: %s\n", strerror(-r));
            goto finish;
        }

        int timeout_msec;
        if (timeout_usec == UINT64_MAX) {
            timeout_msec = -1;
        } else {
            struct timespec ts;
            if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0) {
                timeout_msec = -1;
            } else {
                uint64_t now_usec = (uint64_t)ts.tv_sec * 1000000ULL + ts.tv_nsec / 1000ULL;
                if (timeout_usec <= now_usec) {
                    timeout_msec = 0;
                } else {
                    timeout_msec = (int)((timeout_usec - now_usec + 999) / 1000);
                }
            }
        }

        r = poll(fds, nfds, timeout_msec);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            fprintf(stderr, "failed to poll: %s\n", strerror(errno));
            goto finish;
        }

        if (sysfs_fd >= 0 && (fds[1].revents & (POLLPRI | POLLERR))) {
            (void)ppd_check_external_update(state);
        }
    }

finish:
    global_bus = NULL;
    sd_bus_slot_unref(slot);
    sd_bus_flush_close_unref(bus);
    return r;
}
