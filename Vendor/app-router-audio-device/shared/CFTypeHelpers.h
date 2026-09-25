#ifndef CFTYPEHELPERS_H
#define CFTYPEHELPERS_H

#include <ApplicationServices/ApplicationServices.h>

// A basic smart pointer class meant to be used with Core Foundation object references.
// It owns the reference it holds and releases it when replaced or when it goes out of scope.
template<typename T>
class CFTypeSmartRef {
  public:
    T item;

    CFTypeSmartRef() : item(NULL) {}

    // Takes ownership of |inItem|.
    CFTypeSmartRef(T inItem) : item(inItem) {}

    ~CFTypeSmartRef() {
        if (item) {
            CFRelease(item);
        }
    }

    // Copying would release the same reference twice.
    CFTypeSmartRef(const CFTypeSmartRef &) = delete;
    CFTypeSmartRef &operator=(const CFTypeSmartRef &) = delete;

    // Takes ownership of |inItem| and releases the previous reference.
    CFTypeSmartRef &operator=(T inItem) {
        if (item != inItem) {
            if (item) {
                CFRelease(item);
            }
            item = inItem;
        }
        return *this;
    }

    operator T &() {
        return item;
    }

    operator const T &() const {
        return item;
    }

    // For "copy" out-parameters: releases the current reference first.
    T *operator&() {
        if (item) {
            CFRelease(item);
            item = NULL;
        }
        return &item;
    }

    CFTypeRef ref() const {
        return (CFTypeRef)item;
    }
};

typedef CFTypeSmartRef<CFArrayRef> CFArraySmartRef;
typedef CFTypeSmartRef<CFStringRef> CFStringSmartRef;
typedef CFTypeSmartRef<CFNumberRef> CFNumberSmartRef;
typedef CFTypeSmartRef<CFDictionaryRef> CFDictionarySmartRef;
typedef CFTypeSmartRef<CFPropertyListRef> CFPropertyListSmartRef;

#endif // CFTYPEHELPERS_H
