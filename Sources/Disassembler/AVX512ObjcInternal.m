#import "AVX512ObjcInternal.h"
#import <objc/runtime.h>
#import <stdlib.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <mach/vm_map.h>

BOOL AVX512PointerIsReadable(const void * ptr) {
    if (ptr == NULL) { return NO; }

    vm_address_t address = (vm_address_t)ptr;
    vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    memory_object_name_t object = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(mach_task_self(), &address, &regionSize,
                                    VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                                    &infoCount, &object);
    if (kr != KERN_SUCCESS) { return NO; }
    // vm_region_64 returns the next region at/after the address; make sure it contains ptr.
    if ((vm_address_t)ptr < address) { return NO; }
    if (!(info.protection & VM_PROT_READ)) { return NO; }

    vm_offset_t data = 0;
    mach_msg_type_number_t dataSize = 0;
    kr = vm_read(mach_task_self(), (vm_address_t)ptr, sizeof(uintptr_t), &data, &dataSize);
    if (kr != KERN_SUCCESS) { return NO; }
    vm_deallocate(mach_task_self(), data, dataSize);
    return YES;
}

BOOL AVX512PointerIsValidObjcObject(const void * ptr) {
    if (ptr == NULL) { return NO; }

    // Tagged pointers carry their payload inline; they are valid objects.
    if (avx512_isTaggedPointer(ptr)) { return YES; }

    // Objective-C objects are pointer-aligned.
    if (((uintptr_t)ptr & (sizeof(uintptr_t) - 1)) != 0) { return NO; }

    if (!AVX512PointerIsReadable(ptr)) { return NO; }

    // Heap objects must come from malloc.
    if (malloc_size(ptr) == 0) { return NO; }

    // The isa must resolve to a registered, readable class.
    Class cls = object_getClass((__bridge id)ptr);
    if (cls == Nil) { return NO; }
    if (!AVX512PointerIsReadable((__bridge const void *)cls)) { return NO; }

    const char *name = class_getName(cls);
    if (name == NULL || !AVX512PointerIsReadable(name)) { return NO; }

    return objc_lookUpClass(name) == cls;
}

NSArray<Class> *AVX512GetAllSubclasses(Class cls, BOOL includeClass) {
    if (cls == Nil) { return @[]; }

    unsigned int classCount = objc_getClassList(NULL, 0);
    if (classCount == 0) { return @[]; }

    size_t allocationSize = sizeof(Class) * (size_t)classCount;
    Class *classes = (Class *)malloc(allocationSize);
    if (classes == NULL) { return @[]; }

    classCount = objc_getClassList(classes, classCount);

    NSMutableArray<Class> *result = [NSMutableArray array];
    for (unsigned int i = 0; i < classCount; i++) {
        Class candidate = classes[i];
        if (!includeClass && candidate == cls) { continue; }

        Class superclass = class_getSuperclass(candidate);
        while (superclass != Nil) {
            if (superclass == cls) {
                [result addObject:candidate];
                break;
            }
            superclass = class_getSuperclass(superclass);
        }
    }

    free(classes);
    return result.copy;
}
