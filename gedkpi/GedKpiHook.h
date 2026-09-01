/*
 * GedKpiHook.h - report BufferQueue frame events to MediaTek's ged, so GPU DVFS runs.
 *
 * WHY THIS EXISTS
 *   On MT6789, GPU DVFS is driven from userspace: ged's policy loop (ged_dvfs_run)
 *   only executes when ged is told a frame happened. MediaTek's own libgui does that
 *   by dlopen'ing libged_kpi.so and calling it from the BufferQueue paths. AOSP's
 *   libgui does not, so on this ROM ged never learns a frame occurred, its loop never
 *   runs, gpu_utilization reads 0% WHILE RENDERING and the GPU stays at the OPP it
 *   powered on at -- OPP 0 of 38, the maximum. Measured on v3.1, 2026-09-01:
 *     ged_dvfs_run = 0 hits over 20s of gameplay, against kbase_jd_submit = 12152.
 *   That is true of r32p1, r38p1 and r54p1 alike: it was never a GPU driver problem.
 *
 * THE ABI, DECODED FROM STOCK -- not from any MediaTek source, which we do not have.
 *   Stock libgui carries android::GedKpiDebug + android::GedKpiModuleLoader, and the
 *   wrappers in libged_kpi.so are 4-20 byte forwarders to libged_sys.so whose C++
 *   mangling carries the types (m=unsigned long, i=int, l=long):
 *     _Z18ged_kpi_create_sysmm  _Z19ged_kpi_destroy_sysm
 *     _Z26ged_kpi_buffer_connect_sysmii   _Z29ged_kpi_buffer_disconnect_sysm
 *     _Z30ged_kpi_dequeue_buffer_tag_sysmil
 *     _Z28ged_kpi_queue_buffer_tag_sysmiil
 *     _Z30ged_kpi_acquire_buffer_tag_sysml
 *
 * 🔴 THE THIRD ARGUMENT OF queue IS THE QUEUE DEPTH, NOT THE SLOT.
 *   It reaches ged_gpu_timestamp as QedBuffer_length (struct GED_BRIDGE_IN_GPU_TIMESTAMP:
 *   pid, ullWnd, i32FrameID, fence_fd, QedBuffer_length, isSF). The slot index was the
 *   obvious guess -- it is queueBuffer's first parameter and non-negative -- and it would
 *   have compiled, run, and steered the DVFS governor on a slot number with no crash and
 *   no log line. It was read out of libged_sys rather than assumed.
 *
 * FAILS SOFT, BY DESIGN. If libged_kpi.so is absent every hook is a no-op, which is
 * exactly what stock does ("open libged_kpi.so failed" is a stock string).
 */

#ifndef ANDROID_GUI_GEDKPIHOOK_H
#define ANDROID_GUI_GEDKPIHOOK_H

#include <dlfcn.h>
#include <unistd.h>
#include <cstdint>
#include <log/log.h>
#include <ui/Fence.h>
#include <ui/GraphicBuffer.h>
#include <utils/StrongPointer.h>

namespace android {
namespace gedkpi {

struct Hooks {
    void* handle = nullptr;
    void (*create)(uint64_t, uint64_t) = nullptr;
    void (*destroy)(uint64_t) = nullptr;
    void (*bufferConnect)(uint64_t, int, int) = nullptr;
    void (*bufferDisconnect)(uint64_t) = nullptr;
    void (*dequeueTag)(uint64_t, int, int64_t) = nullptr;
    void (*queueTag)(uint64_t, int, int, int64_t) = nullptr;
    void (*acquireTag)(uint64_t, int64_t) = nullptr;

    Hooks() {
        handle = dlopen("libged_kpi.so", RTLD_NOW);
        if (handle == nullptr) {
            ALOGI("GedKpi: open libged_kpi.so failed (%s); GPU DVFS reporting disabled",
                  dlerror());
            return;
        }
        create           = (void (*)(uint64_t, uint64_t))     dlsym(handle, "ged_kpi_create_wrap");
        destroy          = (void (*)(uint64_t))               dlsym(handle, "ged_kpi_destroy_wrap");
        bufferConnect    = (void (*)(uint64_t, int, int))     dlsym(handle, "ged_kpi_buffer_connect");
        bufferDisconnect = (void (*)(uint64_t))               dlsym(handle, "ged_kpi_buffer_disconnect");
        dequeueTag       = (void (*)(uint64_t, int, int64_t)) dlsym(handle, "ged_kpi_dequeue_buffer_tag_wrap");
        queueTag         = (void (*)(uint64_t, int, int, int64_t)) dlsym(handle, "ged_kpi_queue_buffer_tag_wrap");
        acquireTag       = (void (*)(uint64_t, int64_t))      dlsym(handle, "ged_kpi_acquire_buffer_tag_wrap");
        ALOGI("GedKpi: libged_kpi.so loaded; GPU DVFS reporting enabled");
    }
};

inline const Hooks& hooks() {
    static Hooks sHooks;
    return sHooks;
}

/* Stock dups the fence fd, hands the dup to ged, then closes it; a fence with no fd
 * is reported as -1 and nothing is closed. Mirrored exactly. */
inline int dupFenceFd(const sp<Fence>& fence) {
    if (fence == nullptr || !fence->isValid()) return -1;
    return fence->dup();
}

inline void onCreate(uint64_t id) {
    if (hooks().create) hooks().create(id, id);
}
inline void onDestroy(uint64_t id) {
    if (hooks().destroy) hooks().destroy(id);
}
inline void onConnect(uint64_t id, int api, int pid) {
    if (hooks().bufferConnect) hooks().bufferConnect(id, api, pid);
}
inline void onDisconnect(uint64_t id) {
    if (hooks().bufferDisconnect) hooks().bufferDisconnect(id);
}
inline void onDequeue(uint64_t id, const sp<GraphicBuffer>& buf, const sp<Fence>& fence) {
    if (!hooks().dequeueTag || buf == nullptr) return;
    int fd = dupFenceFd(fence);
    hooks().dequeueTag(id, fd, (int64_t)buf->getId());
    if (fd >= 0) close(fd);
}
inline void onQueue(uint64_t id, const sp<GraphicBuffer>& buf, const sp<Fence>& fence,
                    int queuedBufferCount) {
    if (!hooks().queueTag || buf == nullptr) return;
    int fd = dupFenceFd(fence);
    hooks().queueTag(id, fd, queuedBufferCount, (int64_t)buf->getId());
    if (fd >= 0) close(fd);
}
inline void onAcquire(uint64_t id, const sp<GraphicBuffer>& buf) {
    if (!hooks().acquireTag || buf == nullptr) return;
    hooks().acquireTag(id, (int64_t)buf->getId());
}

}  // namespace gedkpi
}  // namespace android

#endif  // ANDROID_GUI_GEDKPIHOOK_H
