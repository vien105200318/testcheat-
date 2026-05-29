//
//  file.h
//  Cyanide
//
//  Created by seo on 3/29/26.
//

#ifndef file_h
#define file_h

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

// xnu-10002.81.5/bsd/sys/vnode_internal.h
#define VISSHADOW       0x008000        /* vnode is a shadow file */
// xnu-10002.81.5/bsd/sys/mount.h
#define MNT_RDONLY      0x00000001      /* read only filesystem */

uint64_t hide_path(const char* path);
uint64_t reveal_path_by_vnode(uint64_t vnode);
uint64_t overwrite_system_file(char* to, char* from);

// Kernel-level file operations for protected paths
int kernel_copy_file(const char* src_path, const char* dst_path);
int kernel_overwrite_file(const char* src_path, const char* dst_path);

#endif /* file_h */
