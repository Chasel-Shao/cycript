/* Cycript - Optimizing JavaScript Compiler/Runtime
 * Copyright (C) 2009-2012  Jay Freeman (saurik)
*/

/* GNU Lesser General Public License, Version 3 {{{ */
/*
 * Cycript is free software: you can redistribute it and/or modify it under
 * the terms of the GNU Lesser General Public License as published by the
 * Free Software Foundation, either version 3 of the License, or (at your
 * option) any later version.
 *
 * Cycript is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU Lesser General Public
 * License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with Cycript.  If not, see <http://www.gnu.org/licenses/>.
**/
/* }}} */

#ifdef __APPLE__
#include "Struct.hpp"
#endif

#include <Foundation/Foundation.h>

#include "ObjectiveC/Internal.hpp"

#include <objc/objc-api.h>

#include "cycript.hpp"

#include "ObjectiveC/Internal.hpp"

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <JavaScriptCore/JSStringRefCF.h>
#include <WebKit/WebScriptObject.h>
#include <objc/runtime.h>
#endif

#include "Error.hpp"
#include "JavaScript.hpp"
#include "String.hpp"
#include "Execute.hpp"

#include <cmath>
#include <map>

#include <dlfcn.h>

#define CYObjectiveTry_(context) { \
    JSContextRef context_(context); \
    try
#define CYObjectiveTry { \
    try
#define CYObjectiveCatch \
    catch (const CYException &error) { \
        @throw CYCastNSObject(NULL, context_, error.CastJSValue(context_)); \
    } \
}

#define CYPoolTry { \
    id _saved(nil); \
    NSAutoreleasePool *_pool([[NSAutoreleasePool alloc] init]); \
    @try
#define CYPoolCatch(value) \
    @catch (NSException *error) { \
        _saved = [error retain]; \
        throw CYJSError(context, CYCastJSValue(context, error)); \
        return value; \
    } @finally { \
        [_pool release]; \
        if (_saved != nil) \
            [_saved autorelease]; \
    } \
}

#define CYSadTry { \
    @try
#define CYSadCatch(value) \
    @catch (NSException *error ) { \
        throw CYJSError(context, CYCastJSValue(context, error)); \
    } return value; \
}

#ifndef __APPLE__
#define class_getSuperclass GSObjCSuper
#define class_getInstanceVariable GSCGetInstanceVariableDefinition
#define class_getName GSNameFromClass

#define class_removeMethods(cls, list) GSRemoveMethodList(cls, list, YES)

#define ivar_getName(ivar) ((ivar)->ivar_name)
#define ivar_getOffset(ivar) ((ivar)->ivar_offset)
#define ivar_getTypeEncoding(ivar) ((ivar)->ivar_type)

#define method_getName(method) ((method)->method_name)
#define method_getImplementation(method) ((method)->method_imp)
#define method_getTypeEncoding(method) ((method)->method_types)
#define method_setImplementation(method, imp) ((void) ((method)->method_imp = (imp)))

#undef objc_getClass
#define objc_getClass GSClassFromName

#define objc_getProtocol GSProtocolFromName

#define object_getClass GSObjCClass

#define object_getInstanceVariable(object, name, value) ({ \
    objc_ivar *ivar(class_getInstanceVariable(object_getClass(object), name)); \
    _assert(value != NULL); \
    if (ivar != NULL) \
        GSObjCGetVariable(object, ivar_getOffset(ivar), sizeof(void *), value); \
    ivar; \
})

#define object_setIvar(object, ivar, value) ({ \
    void *data = (value); \
    GSObjCSetVariable(object, ivar_getOffset(ivar), sizeof(void *), &data); \
})

#define protocol_getName(protocol) [(protocol) name]
#endif

static void (*$objc_setAssociatedObject)(id object, void *key, id value, objc_AssociationPolicy policy);
static id (*$objc_getAssociatedObject)(id object, void *key);
static void (*$objc_removeAssociatedObjects)(id object);

JSValueRef CYSendMessage(apr_pool_t *pool, JSContextRef context, id self, Class super, SEL _cmd, size_t count, const JSValueRef arguments[], bool initialize, JSValueRef *exception);

/* Objective-C Pool Release {{{ */
apr_status_t CYPoolRelease_(void *data) {
    id object(reinterpret_cast<id>(data));
    [object release];
    return APR_SUCCESS;
}

id CYPoolRelease_(apr_pool_t *pool, id object) {
    if (object == nil)
        return nil;
    else if (pool == NULL)
        return [object autorelease];
    else {
        apr_pool_cleanup_register(pool, object, &CYPoolRelease_, &apr_pool_cleanup_null);
        return object;
    }
}

template <typename Type_>
Type_ CYPoolRelease(apr_pool_t *pool, Type_ object) {
    return (Type_) CYPoolRelease_(pool, (id) object);
}
/* }}} */
/* Objective-C Strings {{{ */
const char *CYPoolCString(apr_pool_t *pool, JSContextRef context, NSString *value) {
    if (pool == NULL)
        return [value UTF8String];
    else {
        size_t size([value maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1);
        char *string(new(pool) char[size]);
        if (![value getCString:string maxLength:size encoding:NSUTF8StringEncoding])
            throw CYJSError(context, "[NSString getCString:maxLength:encoding:] == NO");
        return string;
    }
}

JSStringRef CYCopyJSString(JSContextRef context, NSString *value) {
#ifdef __APPLE__
    return JSStringCreateWithCFString(reinterpret_cast<CFStringRef>(value));
#else
    CYPool pool;
    return CYCopyJSString(CYPoolCString(pool, context, value));
#endif
}

JSStringRef CYCopyJSString(JSContextRef context, NSObject *value) {
    if (value == nil)
        return NULL;
    // XXX: this definition scares me; is anyone using this?!
    NSString *string([value description]);
    return CYCopyJSString(context, string);
}

NSString *CYCopyNSString(const CYUTF8String &value) {
#ifdef __APPLE__
    return (NSString *) CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(value.data), value.size, kCFStringEncodingUTF8, true);
#else
    return [[NSString alloc] initWithBytes:value.data length:value.size encoding:NSUTF8StringEncoding];
#endif
}

NSString *CYCopyNSString(JSContextRef context, JSStringRef value) {
#ifdef __APPLE__
    return (NSString *) JSStringCopyCFString(kCFAllocatorDefault, value);
#else
    CYPool pool;
    return CYCopyNSString(CYPoolUTF8String(pool, context, value));
#endif
}

NSString *CYCopyNSString(JSContextRef context, JSValueRef value) {
    return CYCopyNSString(context, CYJSString(context, value));
}

NSString *CYCastNSString(apr_pool_t *pool, const CYUTF8String &value) {
    return CYPoolRelease(pool, CYCopyNSString(value));
}

NSString *CYCastNSString(apr_pool_t *pool, SEL sel) {
    const char *name(sel_getName(sel));
    return CYPoolRelease(pool, CYCopyNSString(CYUTF8String(name, strlen(name))));
}

NSString *CYCastNSString(apr_pool_t *pool, JSContextRef context, JSStringRef value) {
    return CYPoolRelease(pool, CYCopyNSString(context, value));
}

CYUTF8String CYCastUTF8String(NSString *value) {
    NSData *data([value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO]);
    return CYUTF8String(reinterpret_cast<const char *>([data bytes]), [data length]);
}
/* }}} */

JSValueRef CYCastJSValue(JSContextRef context, NSObject *value);

void CYThrow(JSContextRef context, NSException *error, JSValueRef *exception) {
    if (exception == NULL)
        throw error;
    *exception = CYCastJSValue(context, error);
}

size_t CYGetIndex(NSString *value) {
    return CYGetIndex(CYCastUTF8String(value));
}

bool CYGetOffset(apr_pool_t *pool, JSContextRef context, NSString *value, ssize_t &index) {
    return CYGetOffset(CYPoolCString(pool, context, value), index);
}

static JSClassRef Instance_;

static JSClassRef ArrayInstance_;
static JSClassRef FunctionInstance_;
static JSClassRef ObjectInstance_;
static JSClassRef StringInstance_;

static JSClassRef Internal_;
static JSClassRef Message_;
static JSClassRef Messages_;
static JSClassRef Selector_;
static JSClassRef Super_;

static JSClassRef ObjectiveC_Classes_;
static JSClassRef ObjectiveC_Constants_;
static JSClassRef ObjectiveC_Protocols_;

#ifdef __APPLE__
static JSClassRef ObjectiveC_Image_Classes_;
static JSClassRef ObjectiveC_Images_;
#endif

#ifdef __APPLE__
static Class NSCFBoolean_;
static Class NSCFType_;
static Class NSGenericDeallocHandler_;
static Class NSMessageBuilder_;
static Class NSZombie_;
#else
static Class NSBoolNumber_;
#endif

static Class NSArray_;
static Class NSBlock_;
static Class NSDictionary_;
static Class NSString_;
static Class Object_;

static Type_privateData *Object_type;
static Type_privateData *Selector_type;

Type_privateData *Instance::GetType() const {
    return Object_type;
}

Type_privateData *Selector_privateData::GetType() const {
    return Selector_type;
}

static JSValueRef Instance_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception);

JSValueRef CYGetClassPrototype(JSContextRef context, id self) {
    if (self == nil)
        return CYGetCachedObject(context, CYJSString("Instance_prototype"));

    JSObjectRef global(CYGetGlobalObject(context));
    JSObjectRef cy(CYCastJSObject(context, CYGetProperty(context, global, cy_s)));

    char label[32];
    sprintf(label, "i%p", self);
    CYJSString name(label);

    JSValueRef value(CYGetProperty(context, cy, name));
    if (!JSValueIsUndefined(context, value))
        return value;

    JSClassRef _class(NULL);
    JSValueRef prototype;

    if (self == NSArray_)
        prototype = CYGetCachedObject(context, CYJSString("ArrayInstance_prototype"));
    else if (self == NSBlock_)
        prototype = CYGetCachedObject(context, CYJSString("FunctionInstance_prototype"));
    else if (self == NSDictionary_)
        prototype = CYGetCachedObject(context, CYJSString("ObjectInstance_prototype"));
    else if (self == NSString_)
        prototype = CYGetCachedObject(context, CYJSString("StringInstance_prototype"));
    else
        prototype = CYGetClassPrototype(context, class_getSuperclass(self));

    JSObjectRef object(JSObjectMake(context, _class, NULL));
    JSObjectSetPrototype(context, object, prototype);
    CYSetProperty(context, cy, name, object);

    return object;
}

JSObjectRef Messages::Make(JSContextRef context, Class _class) {
    JSObjectRef value(JSObjectMake(context, Messages_, new Messages(_class)));
    if (Class super = class_getSuperclass(_class))
        JSObjectSetPrototype(context, value, Messages::Make(context, super));
    return value;
}

JSObjectRef Internal::Make(JSContextRef context, id object, JSObjectRef owner) {
    return JSObjectMake(context, Internal_, new Internal(object, context, owner));
}

namespace cy {
JSObjectRef Super::Make(JSContextRef context, id object, Class _class) {
    JSObjectRef value(JSObjectMake(context, Super_, new Super(object, _class)));
    return value;
} }

JSObjectRef Instance::Make(JSContextRef context, id object, Flags flags) {
    JSObjectRef value(JSObjectMake(context, Instance_, new Instance(object, flags)));
    JSObjectSetPrototype(context, value, CYGetClassPrototype(context, object_getClass(object)));
    return value;
}

Instance::~Instance() {
    if ((flags_ & Transient) == 0)
        // XXX: does this handle background threads correctly?
        // XXX: this simply does not work on the console because I'm stupid
        [GetValue() performSelector:@selector(release) withObject:nil afterDelay:0];
}

struct Message_privateData :
    cy::Functor
{
    SEL sel_;

    Message_privateData(SEL sel, const char *type, IMP value = NULL) :
        cy::Functor(type, reinterpret_cast<void (*)()>(value)),
        sel_(sel)
    {
    }
};

JSObjectRef CYMakeInstance(JSContextRef context, id object, bool transient) {
    Instance::Flags flags;

    if (transient)
        flags = Instance::Transient;
    else {
        flags = Instance::None;
        object = [object retain];
    }

    return Instance::Make(context, object, flags);
}

@interface NSMethodSignature (Cycript)
- (NSString *) _typeString;
@end

@interface NSObject (Cycript)

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context;
- (JSType) cy$JSType;

- (JSValueRef) cy$toJSON:(NSString *)key inContext:(JSContextRef)context;
- (NSString *) cy$toCYON:(bool)objective;

- (bool) cy$hasProperty:(NSString *)name;
- (NSObject *) cy$getProperty:(NSString *)name;
- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value;
- (bool) cy$deleteProperty:(NSString *)name;
- (void) cy$getPropertyNames:(JSPropertyNameAccumulatorRef)names inContext:(JSContextRef)context;

+ (bool) cy$hasImplicitProperties;

@end

@protocol Cycript
- (id) cy$box;
- (JSValueRef) cy$valueOfInContext:(JSContextRef)context;
@end

NSString *CYCastNSCYON(id value, bool objective) {
    NSString *string;

    if (value == nil)
        string = @"nil";
    else {
        Class _class(object_getClass(value));
        SEL sel(@selector(cy$toCYON:));

        if (objc_method *toCYON = class_getInstanceMethod(_class, sel))
            string = reinterpret_cast<NSString *(*)(id, SEL, bool)>(method_getImplementation(toCYON))(value, sel, objective);
        else if (objc_method *methodSignatureForSelector = class_getInstanceMethod(_class, @selector(methodSignatureForSelector:))) {
            if (reinterpret_cast<NSMethodSignature *(*)(id, SEL, SEL)>(method_getImplementation(methodSignatureForSelector))(value, @selector(methodSignatureForSelector:), sel) != nil)
                string = [value cy$toCYON:objective];
            else goto fail;
        } else fail: {
            if (false);
#ifdef __APPLE__
            else if (value == NSZombie_)
                string = @"_NSZombie_";
            else if (_class == NSZombie_)
                string = [NSString stringWithFormat:@"<_NSZombie_: %p>", value];
            // XXX: frowny /in/ the pants
            else if (value == NSGenericDeallocHandler_ || value == NSMessageBuilder_ || value == Object_)
                string = nil;
#endif
            else
                string = [NSString stringWithFormat:@"%@", value];
        }

        // XXX: frowny pants
        if (string == nil)
            string = @"undefined";
    }

    return string;
}

#ifdef __APPLE__
struct PropertyAttributes {
    CYPool pool_;

    const char *name;

    const char *variable;

    const char *getter_;
    const char *setter_;

    bool readonly;
    bool copy;
    bool retain;
    bool nonatomic;
    bool dynamic;
    bool weak;
    bool garbage;

    PropertyAttributes(objc_property_t property) :
        variable(NULL),
        getter_(NULL),
        setter_(NULL),
        readonly(false),
        copy(false),
        retain(false),
        nonatomic(false),
        dynamic(false),
        weak(false),
        garbage(false)
    {
        name = property_getName(property);
        const char *attributes(property_getAttributes(property));

        for (char *state, *token(apr_strtok(apr_pstrdup(pool_, attributes), ",", &state)); token != NULL; token = apr_strtok(NULL, ",", &state)) {
            switch (*token) {
                case 'R': readonly = true; break;
                case 'C': copy = true; break;
                case '&': retain = true; break;
                case 'N': nonatomic = true; break;
                case 'G': getter_ = token + 1; break;
                case 'S': setter_ = token + 1; break;
                case 'V': variable = token + 1; break;
            }
        }

        /*if (variable == NULL) {
            variable = property_getName(property);
            size_t size(strlen(variable));
            char *name(new(pool_) char[size + 2]);
            name[0] = '_';
            memcpy(name + 1, variable, size);
            name[size + 1] = '\0';
            variable = name;
        }*/
    }

    const char *Getter() {
        if (getter_ == NULL)
            getter_ = apr_pstrdup(pool_, name);
        return getter_;
    }

    const char *Setter() {
        if (setter_ == NULL && !readonly) {
            size_t length(strlen(name));

            char *temp(new(pool_) char[length + 5]);
            temp[0] = 's';
            temp[1] = 'e';
            temp[2] = 't';

            if (length != 0) {
                temp[3] = toupper(name[0]);
                memcpy(temp + 4, name + 1, length - 1);
            }

            temp[length + 3] = ':';
            temp[length + 4] = '\0';
            setter_ = temp;
        }

        return setter_;
    }

};
#endif

#ifndef __APPLE__
@interface CYWebUndefined : NSObject {
}

+ (CYWebUndefined *) undefined;

@end

@implementation CYWebUndefined

+ (CYWebUndefined *) undefined {
    static CYWebUndefined *instance_([[CYWebUndefined alloc] init]);
    return instance_;
}

@end

#define WebUndefined CYWebUndefined
#endif

/* Bridge: CYJSObject {{{ */
@interface CYJSObject : NSMutableDictionary {
    JSObjectRef object_;
    JSGlobalContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectForKey:(id)key;
- (NSEnumerator *) keyEnumerator;
- (void) setObject:(id)object forKey:(id)key;
- (void) removeObjectForKey:(id)key;

@end
/* }}} */
/* Bridge: CYJSArray {{{ */
@interface CYJSArray : NSMutableArray {
    JSObjectRef object_;
    JSGlobalContextRef context_;
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context;

- (NSUInteger) count;
- (id) objectAtIndex:(NSUInteger)index;

- (void) addObject:(id)anObject;
- (void) insertObject:(id)anObject atIndex:(NSUInteger)index;
- (void) removeLastObject;
- (void) removeObjectAtIndex:(NSUInteger)index;
- (void) replaceObjectAtIndex:(NSUInteger)index withObject:(id)anObject;

@end
/* }}} */

_finline bool CYJSValueIsNSObject(JSContextRef context, JSValueRef value) {
    return JSValueIsObjectOfClass(context, value, Instance_);
}

_finline bool CYJSValueIsInstanceOfCachedConstructor(JSContextRef context, JSValueRef value, JSStringRef cache) {
    JSValueRef exception(NULL);
    JSObjectRef constructor(CYGetCachedObject(context, cache));
    bool is(JSValueIsInstanceOfConstructor(context, value, constructor, &exception));
    CYThrow(context, exception);
    return is;
}

NSObject *CYCastNSObject(apr_pool_t *pool, JSContextRef context, JSObjectRef object) {
    if (CYJSValueIsNSObject(context, object)) {
        Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
        return internal->GetValue();
    }

    bool array(CYJSValueIsInstanceOfCachedConstructor(context, object, Array_s));
    id value(array ? [CYJSArray alloc] : [CYJSObject alloc]);
    return CYPoolRelease(pool, [value initWithJSObject:object inContext:context]);
}

NSNumber *CYCopyNSNumber(JSContextRef context, JSValueRef value) {
    return [[NSNumber alloc] initWithDouble:CYCastDouble(context, value)];
}

#ifndef __APPLE__
@interface NSBoolNumber : NSNumber {
}
@end
#endif

id CYNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value, bool cast) {
    id object;
    bool copy;

    switch (JSType type = JSValueGetType(context, value)) {
        case kJSTypeUndefined:
            object = [WebUndefined undefined];
            copy = false;
        break;

        case kJSTypeNull:
            return NULL;
        break;

        case kJSTypeBoolean:
#ifdef __APPLE__
            object = (id) (CYCastBool(context, value) ? kCFBooleanTrue : kCFBooleanFalse);
            copy = false;
#else
            object = [[NSBoolNumber alloc] initWithBool:CYCastBool(context, value)];
            copy = true;
#endif
        break;

        case kJSTypeNumber:
            object = CYCopyNSNumber(context, value);
            copy = true;
        break;

        case kJSTypeString:
            object = CYCopyNSString(context, value);
            copy = true;
        break;

        case kJSTypeObject:
            // XXX: this might could be more efficient
            object = CYCastNSObject(pool, context, (JSObjectRef) value);
            copy = false;
        break;

        default:
            throw CYJSError(context, "JSValueGetType() == 0x%x", type);
        break;
    }

    if (cast != copy)
        return object;
    else if (copy)
        return CYPoolRelease(pool, object);
    else
        return [object retain];
}

NSObject *CYCastNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return CYNSObject(pool, context, value, true);
}

NSObject *CYCopyNSObject(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    return CYNSObject(pool, context, value, false);
}

/* Bridge: NSArray {{{ */
@implementation NSArray (Cycript)

- (id) cy$box {
    return [[self mutableCopy] autorelease];
}

- (NSString *) cy$toCYON:(bool)objective {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"@["];

    bool comma(false);
#ifdef __APPLE__
    for (id object in self) {
#else
    for (size_t index(0), count([self count]); index != count; ++index) {
        id object([self objectAtIndex:index]);
#endif
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        if (object == nil || [object cy$JSType] != kJSTypeUndefined)
            [json appendString:CYCastNSCYON(object, true)];
        else {
            [json appendString:@","];
            comma = false;
        }
    }

    [json appendString:@"]"];
    return json;
}

- (bool) cy$hasProperty:(NSString *)name {
    if ([name isEqualToString:@"length"])
        return true;

    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self count])
        return [super cy$hasProperty:name];
    else
        return true;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    if ([name isEqualToString:@"length"]) {
        NSUInteger count([self count]);
#ifdef __APPLE__
        return [NSNumber numberWithUnsignedInteger:count];
#else
        return [NSNumber numberWithUnsignedInt:count];
#endif
    }

    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self count])
        return [super cy$getProperty:name];
    else
        return [self objectAtIndex:index];
}

- (void) cy$getPropertyNames:(JSPropertyNameAccumulatorRef)names inContext:(JSContextRef)context {
    [super cy$getPropertyNames:names inContext:context];

    for (size_t index(0), count([self count]); index != count; ++index) {
        id object([self objectAtIndex:index]);
        if (object == nil || [object cy$JSType] != kJSTypeUndefined) {
            char name[32];
            sprintf(name, "%zu", index);
            JSPropertyNameAccumulatorAddName(names, CYJSString(name));
        }
    }
}

+ (bool) cy$hasImplicitProperties {
    return false;
}

@end
/* }}} */
/* Bridge: NSBlock {{{ */
#ifdef __APPLE__
@interface NSBlock
- (void) invoke;
@end
#endif
/* }}} */
/* Bridge: NSBoolNumber {{{ */
#ifndef __APPLE__
@implementation NSBoolNumber (Cycript)

- (JSType) cy$JSType {
    return kJSTypeBoolean;
}

- (NSString *) cy$toCYON:(bool)objective {
    NSString *value([self boolValue] ? @"true" : @"false");
    return objective ? value : [NSString stringWithFormat:@"@%@", value];
}

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context { CYObjectiveTry_(context) {
    return CYCastJSValue(context, (bool) [self boolValue]);
} CYObjectiveCatch }

@end
#endif
/* }}} */
/* Bridge: NSDictionary {{{ */
@implementation NSDictionary (Cycript)

- (id) cy$box {
    return [[self mutableCopy] autorelease];
}

- (NSString *) cy$toCYON:(bool)objective {
    NSMutableString *json([[[NSMutableString alloc] init] autorelease]);
    [json appendString:@"@{"];

    bool comma(false);
#ifdef __APPLE__
    for (NSObject *key in self) {
#else
    NSEnumerator *keys([self keyEnumerator]);
    while (NSObject *key = [keys nextObject]) {
#endif
        if (comma)
            [json appendString:@","];
        else
            comma = true;
        [json appendString:CYCastNSCYON(key, true)];
        [json appendString:@":"];
        NSObject *object([self objectForKey:key]);
        [json appendString:CYCastNSCYON(object, true)];
    }

    [json appendString:@"}"];
    return json;
}

- (bool) cy$hasProperty:(NSString *)name {
    return [self objectForKey:name] != nil;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    return [self objectForKey:name];
}

- (void) cy$getPropertyNames:(JSPropertyNameAccumulatorRef)names inContext:(JSContextRef)context {
    [super cy$getPropertyNames:names inContext:context];

#ifdef __APPLE__
    for (NSObject *key in self) {
#else
    NSEnumerator *keys([self keyEnumerator]);
    while (NSObject *key = [keys nextObject]) {
#endif
        JSPropertyNameAccumulatorAddName(names, CYJSString(context, key));
    }
}

+ (bool) cy$hasImplicitProperties {
    return false;
}

@end
/* }}} */
/* Bridge: NSMutableArray {{{ */
@implementation NSMutableArray (Cycript)

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    if ([name isEqualToString:@"length"]) {
        // XXX: is this not intelligent?
        NSNumber *number(reinterpret_cast<NSNumber *>(value));
#ifdef __APPLE__
        NSUInteger size([number unsignedIntegerValue]);
#else
        NSUInteger size([number unsignedIntValue]);
#endif
        NSUInteger count([self count]);
        if (size < count)
            [self removeObjectsInRange:NSMakeRange(size, count - size)];
        else if (size != count) {
            WebUndefined *undefined([WebUndefined undefined]);
            for (size_t i(count); i != size; ++i)
                [self addObject:undefined];
        }
        return true;
    }

    size_t index(CYGetIndex(name));
    if (index == _not(size_t))
        return [super cy$setProperty:name to:value];

    id object(value ?: [NSNull null]);

    size_t count([self count]);
    if (index < count)
        [self replaceObjectAtIndex:index withObject:object];
    else {
        if (index != count) {
            WebUndefined *undefined([WebUndefined undefined]);
            for (size_t i(count); i != index; ++i)
                [self addObject:undefined];
        }

        [self addObject:object];
    }

    return true;
}

- (bool) cy$deleteProperty:(NSString *)name {
    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self count])
        return [super cy$deleteProperty:name];
    [self replaceObjectAtIndex:index withObject:[WebUndefined undefined]];
    return true;
}

@end
/* }}} */
/* Bridge: NSMutableDictionary {{{ */
@implementation NSMutableDictionary (Cycript)

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    [self setObject:(value ?: [NSNull null]) forKey:name];
    return true;
}

- (bool) cy$deleteProperty:(NSString *)name {
    if ([self objectForKey:name] == nil)
        return false;
    else {
        [self removeObjectForKey:name];
        return true;
    }
}

@end
/* }}} */
/* Bridge: NSNumber {{{ */
@implementation NSNumber (Cycript)

- (JSType) cy$JSType {
#ifdef __APPLE__
    // XXX: this just seems stupid
    if ([self class] == NSCFBoolean_)
        return kJSTypeBoolean;
#endif
    return kJSTypeNumber;
}

- (NSString *) cy$toCYON:(bool)objective {
    NSString *value([self cy$JSType] != kJSTypeBoolean ? [self stringValue] : [self boolValue] ? @"true" : @"false");
    return objective ? value : [NSString stringWithFormat:@"@%@", value];
}

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context { CYObjectiveTry_(context) {
    return [self cy$JSType] != kJSTypeBoolean ? CYCastJSValue(context, [self doubleValue]) : CYCastJSValue(context, static_cast<bool>([self boolValue]));
} CYObjectiveCatch }

@end
/* }}} */
/* Bridge: NSNull {{{ */
@implementation NSNull (Cycript)

- (JSType) cy$JSType {
    return kJSTypeNull;
}

- (NSString *) cy$toCYON:(bool)objective {
    NSString *value(@"null");
    return objective ? value : [NSString stringWithFormat:@"@%@", value];
}

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context { CYObjectiveTry_(context) {
    return CYJSNull(context);
} CYObjectiveCatch }

@end
/* }}} */
/* Bridge: NSObject {{{ */
@implementation NSObject (Cycript)

- (id) cy$box {
    return self;
}

- (JSValueRef) cy$toJSON:(NSString *)key inContext:(JSContextRef)context {
    return [self cy$valueOfInContext:context];
}

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context { CYObjectiveTry_(context) {
    return NULL;
} CYObjectiveCatch }

- (JSType) cy$JSType {
    return kJSTypeObject;
}

- (NSString *) cy$toCYON:(bool)objective {
    return [[self description] cy$toCYON:objective];
}

- (bool) cy$hasProperty:(NSString *)name {
    return false;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    return nil;
}

- (bool) cy$setProperty:(NSString *)name to:(NSObject *)value {
    return false;
}

- (bool) cy$deleteProperty:(NSString *)name {
    return false;
}

- (void) cy$getPropertyNames:(JSPropertyNameAccumulatorRef)names inContext:(JSContextRef)context {
}

+ (bool) cy$hasImplicitProperties {
    return true;
}

@end
/* }}} */
/* Bridge: NSProxy {{{ */
@implementation NSProxy (Cycript)

- (NSString *) cy$toCYON:(bool)objective {
    return [[self description] cy$toCYON:objective];
}

@end
/* }}} */
/* Bridge: NSString {{{ */
@implementation NSString (Cycript)

- (id) cy$box {
    return [[self copy] autorelease];
}

- (JSType) cy$JSType {
    return kJSTypeString;
}

- (NSString *) cy$toCYON:(bool)objective {
    std::ostringstream str;
    if (!objective)
        str << '@';
    CYUTF8String string(CYCastUTF8String(self));
    CYStringify(str, string.data, string.size);
    std::string value(str.str());
    return CYCastNSString(NULL, CYUTF8String(value.c_str(), value.size()));
}

- (bool) cy$hasProperty:(NSString *)name {
    if ([name isEqualToString:@"length"])
        return true;

    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self length])
        return [super cy$hasProperty:name];
    else
        return true;
}

- (NSObject *) cy$getProperty:(NSString *)name {
    if ([name isEqualToString:@"length"]) {
        NSUInteger count([self length]);
#ifdef __APPLE__
        return [NSNumber numberWithUnsignedInteger:count];
#else
        return [NSNumber numberWithUnsignedInt:count];
#endif
    }

    size_t index(CYGetIndex(name));
    if (index == _not(size_t) || index >= [self length])
        return [super cy$getProperty:name];
    else
        return [self substringWithRange:NSMakeRange(index, 1)];
}

- (void) cy$getPropertyNames:(JSPropertyNameAccumulatorRef)names inContext:(JSContextRef)context {
    [super cy$getPropertyNames:names inContext:context];

    for (size_t index(0), length([self length]); index != length; ++index) {
        char name[32];
        sprintf(name, "%zu", index);
        JSPropertyNameAccumulatorAddName(names, CYJSString(name));
    }
}

// XXX: this might be overly restrictive for NSString; I think I need a half-way between /injecting/ implicit properties and /accepting/ implicit properties
+ (bool) cy$hasImplicitProperties {
    return false;
}

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context { CYObjectiveTry_(context) {
    return CYCastJSValue(context, CYJSString(context, self));
} CYObjectiveCatch }

@end
/* }}} */
/* Bridge: WebUndefined {{{ */
@implementation WebUndefined (Cycript)

- (JSType) cy$JSType {
    return kJSTypeUndefined;
}

- (NSString *) cy$toCYON {
    NSString *value(@"undefined");
    return value; // XXX: maybe use the below code, adding @undefined?
    //return objective ? value : [NSString stringWithFormat:@"@%@", value];
}

- (JSValueRef) cy$valueOfInContext:(JSContextRef)context { CYObjectiveTry_(context) {
    return CYJSUndefined(context);
} CYObjectiveCatch }

@end
/* }}} */

static bool CYIsClass(id self) {
#ifdef __APPLE__
    return class_isMetaClass(object_getClass(self));
#else
    return GSObjCIsClass(self);
#endif
}

Class CYCastClass(apr_pool_t *pool, JSContextRef context, JSValueRef value) {
    id self(CYCastNSObject(pool, context, value));
    if (CYIsClass(self))
        return (Class) self;
    throw CYJSError(context, "got something that is not a Class");
    return NULL;
}

NSArray *CYCastNSArray(JSContextRef context, JSPropertyNameArrayRef names) {
    CYPool pool;
    size_t size(JSPropertyNameArrayGetCount(names));
    NSMutableArray *array([NSMutableArray arrayWithCapacity:size]);
    for (size_t index(0); index != size; ++index)
        [array addObject:CYCastNSString(pool, context, JSPropertyNameArrayGetNameAtIndex(names, index))];
    return array;
}

JSValueRef CYCastJSValue(JSContextRef context, NSObject *value) { CYPoolTry {
    if (value == nil)
        return CYJSNull(context);
    else
        return CYMakeInstance(context, value, false);
} CYPoolCatch(NULL) return /*XXX*/ NULL; }

@implementation CYJSObject

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context { CYObjectiveTry {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = CYGetJSContext(context);
        JSGlobalContextRetain(context_);
        JSValueProtect(context_, object_);
    } return self;
} CYObjectiveCatch }

- (void) dealloc { CYObjectiveTry {
    JSValueUnprotect(context_, object_);
    JSGlobalContextRelease(context_);
    [super dealloc];
} CYObjectiveCatch }

- (NSString *) cy$toCYON:(bool)objective { CYObjectiveTry {
    CYPool pool;
    JSValueRef exception(NULL);
    const char *cyon(CYPoolCCYON(pool, context_, object_));
    CYThrow(context_, exception);
    if (cyon == NULL)
        return [super cy$toCYON:objective];
    else
        return [NSString stringWithUTF8String:cyon];
} CYObjectiveCatch }

- (NSUInteger) count { CYObjectiveTry {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    size_t size(JSPropertyNameArrayGetCount(names));
    JSPropertyNameArrayRelease(names);
    return size;
} CYObjectiveCatch }

- (id) objectForKey:(id)key { CYObjectiveTry {
    JSValueRef value(CYGetProperty(context_, object_, CYJSString(context_, (NSObject *) key)));
    if (JSValueIsUndefined(context_, value))
        return nil;
    return CYCastNSObject(NULL, context_, value) ?: [NSNull null];
} CYObjectiveCatch }

- (NSEnumerator *) keyEnumerator { CYObjectiveTry {
    JSPropertyNameArrayRef names(JSObjectCopyPropertyNames(context_, object_));
    NSEnumerator *enumerator([CYCastNSArray(context_, names) objectEnumerator]);
    JSPropertyNameArrayRelease(names);
    return enumerator;
} CYObjectiveCatch }

- (void) setObject:(id)object forKey:(id)key { CYObjectiveTry {
    CYSetProperty(context_, object_, CYJSString(context_, (NSObject *) key), CYCastJSValue(context_, (NSString *) object));
} CYObjectiveCatch }

- (void) removeObjectForKey:(id)key { CYObjectiveTry {
    JSValueRef exception(NULL);
    (void) JSObjectDeleteProperty(context_, object_, CYJSString(context_, (NSObject *) key), &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

@end

@implementation CYJSArray

- (NSString *) cy$toCYON:(bool)objective {
    CYPool pool;
    return [NSString stringWithUTF8String:CYPoolCCYON(pool, context_, object_)];
}

- (id) initWithJSObject:(JSObjectRef)object inContext:(JSContextRef)context { CYObjectiveTry {
    if ((self = [super init]) != nil) {
        object_ = object;
        context_ = CYGetJSContext(context);
        JSGlobalContextRetain(context_);
        JSValueProtect(context_, object_);
    } return self;
} CYObjectiveCatch }

- (void) dealloc { CYObjectiveTry {
    JSValueUnprotect(context_, object_);
    JSGlobalContextRelease(context_);
    [super dealloc];
} CYObjectiveCatch }

- (NSUInteger) count { CYObjectiveTry {
    return CYArrayLength(context_, object_);
} CYObjectiveCatch }

- (id) objectAtIndex:(NSUInteger)index { CYObjectiveTry {
    size_t bounds([self count]);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray objectAtIndex:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    JSValueRef exception(NULL);
    JSValueRef value(JSObjectGetPropertyAtIndex(context_, object_, index, &exception));
    CYThrow(context_, exception);
    return CYCastNSObject(NULL, context_, value) ?: [NSNull null];
} CYObjectiveCatch }

- (void) addObject:(id)object { CYObjectiveTry {
    CYArrayPush(context_, object_, CYCastJSValue(context_, (NSObject *) object));
} CYObjectiveCatch }

- (void) insertObject:(id)object atIndex:(NSUInteger)index { CYObjectiveTry {
    size_t bounds([self count] + 1);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray insertObject:atIndex:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    JSValueRef exception(NULL);
    JSValueRef arguments[3];
    arguments[0] = CYCastJSValue(context_, index);
    arguments[1] = CYCastJSValue(context_, 0);
    arguments[2] = CYCastJSValue(context_, (NSObject *) object);
    JSObjectRef Array(CYGetCachedObject(context_, CYJSString("Array_prototype")));
    JSObjectCallAsFunction(context_, CYCastJSObject(context_, CYGetProperty(context_, Array, splice_s)), object_, 3, arguments, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) removeLastObject { CYObjectiveTry {
    JSValueRef exception(NULL);
    JSObjectRef Array(CYGetCachedObject(context_, CYJSString("Array_prototype")));
    JSObjectCallAsFunction(context_, CYCastJSObject(context_, CYGetProperty(context_, Array, pop_s)), object_, 0, NULL, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) removeObjectAtIndex:(NSUInteger)index { CYObjectiveTry {
    size_t bounds([self count]);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray removeObjectAtIndex:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    JSValueRef exception(NULL);
    JSValueRef arguments[2];
    arguments[0] = CYCastJSValue(context_, index);
    arguments[1] = CYCastJSValue(context_, 1);
    JSObjectRef Array(CYGetCachedObject(context_, CYJSString("Array_prototype")));
    JSObjectCallAsFunction(context_, CYCastJSObject(context_, CYGetProperty(context_, Array, splice_s)), object_, 2, arguments, &exception);
    CYThrow(context_, exception);
} CYObjectiveCatch }

- (void) replaceObjectAtIndex:(NSUInteger)index withObject:(id)object { CYObjectiveTry {
    size_t bounds([self count]);
    if (index >= bounds)
        @throw [NSException exceptionWithName:NSRangeException reason:[NSString stringWithFormat:@"*** -[CYJSArray replaceObjectAtIndex:withObject:]: index (%zu) beyond bounds (%zu)", index, bounds] userInfo:nil];
    CYSetProperty(context_, object_, index, CYCastJSValue(context_, (NSObject *) object));
} CYObjectiveCatch }

@end

// XXX: inherit from or replace with CYJSObject
@interface CYInternal : NSObject {
    JSGlobalContextRef context_;
    JSObjectRef object_;
}

@end

@implementation CYInternal

- (void) dealloc {
    JSValueUnprotect(context_, object_);
    JSGlobalContextRelease(context_);
    [super dealloc];
}

- (id) initInContext:(JSContextRef)context {
    if ((self = [super init]) != nil) {
        context_ = CYGetJSContext(context);
        JSGlobalContextRetain(context_);
    } return self;
}

- (bool) hasProperty:(JSStringRef)name inContext:(JSContextRef)context {
    if (object_ == NULL)
        return false;

    return JSObjectHasProperty(context, object_, name);
}

- (JSValueRef) getProperty:(JSStringRef)name inContext:(JSContextRef)context {
    if (object_ == NULL)
        return NULL;

    return CYGetProperty(context, object_, name);
}

- (void) setProperty:(JSStringRef)name toValue:(JSValueRef)value inContext:(JSContextRef)context {
    @synchronized (self) {
        if (object_ == NULL) {
            object_ = JSObjectMake(context, NULL, NULL);
            JSValueProtect(context, object_);
        }
    }

    CYSetProperty(context, object_, name, value);
}

+ (CYInternal *) get:(id)object {
    if ($objc_getAssociatedObject == NULL)
        return nil;

    @synchronized (object) {
        if (CYInternal *internal = $objc_getAssociatedObject(object, @selector(cy$internal)))
            return internal;
    }

    return nil;
}

+ (CYInternal *) set:(id)object inContext:(JSContextRef)context {
    if ($objc_getAssociatedObject == NULL)
        return nil;

    @synchronized (object) {
        if (CYInternal *internal = $objc_getAssociatedObject(object, @selector(cy$internal)))
            return internal;

        if ($objc_setAssociatedObject == NULL)
            return nil;

        CYInternal *internal([[[CYInternal alloc] initInContext:context] autorelease]);
        objc_setAssociatedObject(object, @selector(cy$internal), internal, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return internal;
    }

    return nil;
}

@end

static JSObjectRef CYMakeSelector(JSContextRef context, SEL sel) {
    Selector_privateData *internal(new Selector_privateData(sel));
    return JSObjectMake(context, Selector_, internal);
}

static SEL CYCastSEL(JSContextRef context, JSValueRef value) {
    if (JSValueIsObjectOfClass(context, value, Selector_)) {
        Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate((JSObjectRef) value)));
        return reinterpret_cast<SEL>(internal->value_);
    } else
        return CYCastPointer<SEL>(context, value);
}

void *CYObjectiveC_ExecuteStart(JSContextRef context) { CYSadTry {
    return (void *) [[NSAutoreleasePool alloc] init];
} CYSadCatch(NULL) }

void CYObjectiveC_ExecuteEnd(JSContextRef context, void *handle) { CYSadTry {
    return [(NSAutoreleasePool *) handle release];
} CYSadCatch() }

JSValueRef CYObjectiveC_RuntimeProperty(JSContextRef context, CYUTF8String name) { CYPoolTry {
    if (name == "nil")
        return Instance::Make(context, nil);
    if (Class _class = objc_getClass(name.data))
        return CYMakeInstance(context, _class, true);
    if (Protocol *protocol = objc_getProtocol(name.data))
        return CYMakeInstance(context, protocol, true);
    return NULL;
} CYPoolCatch(NULL) return /*XXX*/ NULL; }

static void CYObjectiveC_CallFunction(JSContextRef context, ffi_cif *cif, void (*function)(), uint8_t *value, void **values) { CYSadTry {
    ffi_call(cif, function, value, values);
} CYSadCatch() }

static bool CYObjectiveC_PoolFFI(apr_pool_t *pool, JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, JSValueRef value) { CYSadTry {
    switch (type->primitive) {
        // XXX: do something epic about blocks
        case sig::block_P:
        case sig::object_P:
        case sig::typename_P:
            *reinterpret_cast<id *>(data) = CYCastNSObject(pool, context, value);
        break;

        case sig::selector_P:
            *reinterpret_cast<SEL *>(data) = CYCastSEL(context, value);
        break;

        default:
            return false;
    }

    return true;
} CYSadCatch(false) }

static JSValueRef CYObjectiveC_FromFFI(JSContextRef context, sig::Type *type, ffi_type *ffi, void *data, bool initialize, JSObjectRef owner) { CYPoolTry {
    switch (type->primitive) {
        // XXX: do something epic about blocks
        case sig::block_P:
        case sig::object_P:
            if (NSObject *object = *reinterpret_cast<NSObject **>(data)) {
                JSValueRef value(CYCastJSValue(context, object));
                if (initialize)
                    [object release];
                return value;
            } else goto null;

        case sig::typename_P:
            return CYMakeInstance(context, *reinterpret_cast<Class *>(data), true);

        case sig::selector_P:
            if (SEL sel = *reinterpret_cast<SEL *>(data))
                return CYMakeSelector(context, sel);
            else goto null;

        null:
            return CYJSNull(context);
        default:
            return NULL;
    }
} CYPoolCatch(NULL) return /*XXX*/ NULL; }

static bool CYImplements(id object, Class _class, SEL selector, bool devoid = false) {
    if (objc_method *method = class_getInstanceMethod(_class, selector)) {
        if (!devoid)
            return true;
#if OBJC_API_VERSION >= 2
        char type[16];
        method_getReturnType(method, type, sizeof(type));
#else
        const char *type(method_getTypeEncoding(method));
#endif
        if (type[0] != 'v')
            return true;
    }

    // XXX: possibly use a more "awesome" check?
    return false;
}

static const char *CYPoolTypeEncoding(apr_pool_t *pool, JSContextRef context, SEL sel, objc_method *method) {
    if (method != NULL)
        return method_getTypeEncoding(method);

    const char *name(sel_getName(sel));
    size_t length(strlen(name));

    char keyed[length + 2];
    keyed[0] = '6';
    keyed[length + 1] = '\0';
    memcpy(keyed + 1, name, length);

    if (CYBridgeEntry *entry = CYBridgeHash(keyed, length + 1))
        return entry->value_;

    return NULL;
}

static void MessageClosure_(ffi_cif *cif, void *result, void **arguments, void *arg) {
    Closure_privateData *internal(reinterpret_cast<Closure_privateData *>(arg));

    JSContextRef context(internal->context_);

    size_t count(internal->cif_.nargs);
    JSValueRef values[count];

    for (size_t index(0); index != count; ++index)
        values[index] = CYFromFFI(context, internal->signature_.elements[1 + index].type, internal->cif_.arg_types[index], arguments[index]);

    JSObjectRef _this(CYCastJSObject(context, values[0]));

    JSValueRef value(CYCallAsFunction(context, internal->function_, _this, count - 2, values + 2));
    CYPoolFFI(NULL, context, internal->signature_.elements[0].type, internal->cif_.rtype, result, value);
}

static JSObjectRef CYMakeMessage(JSContextRef context, SEL sel, IMP imp, const char *type) {
    Message_privateData *internal(new Message_privateData(sel, type, imp));
    return JSObjectMake(context, Message_, internal);
}

static IMP CYMakeMessage(JSContextRef context, JSValueRef value, const char *type) {
    JSObjectRef function(CYCastJSObject(context, value));
    Closure_privateData *internal(CYMakeFunctor_(context, function, type, &MessageClosure_));
    // XXX: see notes in Library.cpp about needing to leak
    return reinterpret_cast<IMP>(internal->GetValue());
}

static bool Messages_hasProperty(JSContextRef context, JSObjectRef object, JSStringRef property) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    if (SEL sel = sel_getUid(name))
        if (class_getInstanceMethod(_class, sel) != NULL)
            return true;

    return false;
}

static JSValueRef Messages_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    if (SEL sel = sel_getUid(name))
        if (objc_method *method = class_getInstanceMethod(_class, sel))
            return CYMakeMessage(context, sel, method_getImplementation(method), method_getTypeEncoding(method));

    return NULL;
}

static bool Messages_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    SEL sel(sel_registerName(name));

    objc_method *method(class_getInstanceMethod(_class, sel));

    const char *type;
    IMP imp;

    if (JSValueIsObjectOfClass(context, value, Message_)) {
        Message_privateData *message(reinterpret_cast<Message_privateData *>(JSObjectGetPrivate((JSObjectRef) value)));
        type = sig::Unparse(pool, &message->signature_);
        imp = reinterpret_cast<IMP>(message->GetValue());
    } else {
        type = CYPoolTypeEncoding(pool, context, sel, method);
        imp = CYMakeMessage(context, value, type);
    }

    if (method != NULL)
        method_setImplementation(method, imp);
    else {
#ifdef GNU_RUNTIME
        GSMethodList list(GSAllocMethodList(1));
        GSAppendMethodToList(list, sel, type, imp, YES);
        GSAddMethodList(_class, list, YES);
        GSFlushMethodCacheForClass(_class);
#else
        class_addMethod(_class, sel, imp, type);
#endif
    }

    return true;
}

#if 0 && OBJC_API_VERSION < 2
static bool Messages_deleteProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));

    if (SEL sel = sel_getUid(name))
        if (objc_method *method = class_getInstanceMethod(_class, sel)) {
            objc_method_list list = {NULL, 1, {method}};
            class_removeMethods(_class, &list);
            return true;
        }

    return false;
}
#endif

static void Messages_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Messages *internal(reinterpret_cast<Messages *>(JSObjectGetPrivate(object)));
    Class _class(internal->GetValue());

#if OBJC_API_VERSION >= 2
    unsigned int size;
    objc_method **data(class_copyMethodList(_class, &size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(sel_getName(method_getName(data[i]))));
    free(data);
#else
    for (objc_method_list *methods(_class->methods); methods != NULL; methods = methods->method_next)
        for (int i(0); i != methods->method_count; ++i)
            JSPropertyNameAccumulatorAddName(names, CYJSString(sel_getName(method_getName(&methods->method_list[i]))));
#endif
}

static bool CYHasImplicitProperties(Class _class) {
    // XXX: this is an evil hack to deal with NSProxy; fix elsewhere
    if (!CYImplements(_class, object_getClass(_class), @selector(cy$hasImplicitProperties)))
        return true;
    return [_class cy$hasImplicitProperties];
}

static bool Instance_hasProperty(JSContextRef context, JSObjectRef object, JSStringRef property) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    if (JSStringIsEqualToUTF8CString(property, "$cyi"))
        return true;

    CYPool pool;
    NSString *name(CYCastNSString(pool, context, property));

    if (CYInternal *internal = [CYInternal get:self])
        if ([internal hasProperty:property inContext:context])
            return true;

    Class _class(object_getClass(self));

    CYPoolTry {
        // XXX: this is an evil hack to deal with NSProxy; fix elsewhere
        if (CYImplements(self, _class, @selector(cy$hasProperty:)))
            if ([self cy$hasProperty:name])
                return true;
    } CYPoolCatch(false)

    const char *string(CYPoolCString(pool, context, name));

#ifdef __APPLE__
    if (class_getProperty(_class, string) != NULL)
        return true;
#endif

    if (CYHasImplicitProperties(_class))
        if (SEL sel = sel_getUid(string))
            if (CYImplements(self, _class, sel, true))
                return true;

    return false;
}

static JSValueRef Instance_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    if (JSStringIsEqualToUTF8CString(property, "$cyi"))
        return Internal::Make(context, self, object);

    CYPool pool;
    NSString *name(CYCastNSString(pool, context, property));

    if (CYInternal *internal = [CYInternal get:self])
        if (JSValueRef value = [internal getProperty:property inContext:context])
            return value;

    CYPoolTry {
        if (NSObject *data = [self cy$getProperty:name])
            return CYCastJSValue(context, data);
    } CYPoolCatch(NULL)

    const char *string(CYPoolCString(pool, context, name));
    Class _class(object_getClass(self));

#ifdef __APPLE__
    if (objc_property_t property = class_getProperty(_class, string)) {
        PropertyAttributes attributes(property);
        SEL sel(sel_registerName(attributes.Getter()));
        return CYSendMessage(pool, context, self, NULL, sel, 0, NULL, false, exception);
    }
#endif

    if (CYHasImplicitProperties(_class))
        if (SEL sel = sel_getUid(string))
            if (CYImplements(self, _class, sel, true))
                return CYSendMessage(pool, context, self, NULL, sel, 0, NULL, false, exception);

    return NULL;
} CYCatch }

static bool Instance_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    CYPool pool;

    NSString *name(CYCastNSString(pool, context, property));
    NSObject *data(CYCastNSObject(pool, context, value));

    CYPoolTry {
        if ([self cy$setProperty:name to:data])
            return true;
    } CYPoolCatch(NULL)

    const char *string(CYPoolCString(pool, context, name));
    Class _class(object_getClass(self));

#ifdef __APPLE__
    if (objc_property_t property = class_getProperty(_class, string)) {
        PropertyAttributes attributes(property);
        if (const char *setter = attributes.Setter()) {
            SEL sel(sel_registerName(setter));
            JSValueRef arguments[1] = {value};
            CYSendMessage(pool, context, self, NULL, sel, 1, arguments, false, exception);
            return true;
        }
    }
#endif

    size_t length(strlen(string));

    char set[length + 5];

    set[0] = 's';
    set[1] = 'e';
    set[2] = 't';

    if (string[0] != '\0') {
        set[3] = toupper(string[0]);
        memcpy(set + 4, string + 1, length - 1);
    }

    set[length + 3] = ':';
    set[length + 4] = '\0';

    if (SEL sel = sel_getUid(set))
        if (CYImplements(self, _class, sel)) {
            JSValueRef arguments[1] = {value};
            CYSendMessage(pool, context, self, NULL, sel, 1, arguments, false, exception);
            return true;
        }

    if (CYInternal *internal = [CYInternal set:self inContext:context]) {
        [internal setProperty:property toValue:value inContext:context];
        return true;
    }

    return false;
} CYCatch }

static bool Instance_deleteProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    CYPoolTry {
        NSString *name(CYCastNSString(NULL, context, property));
        return [self cy$deleteProperty:name];
    } CYPoolCatch(NULL)
} CYCatch return /*XXX*/ NULL; }

static void Instance_getPropertyNames_message(JSPropertyNameAccumulatorRef names, objc_method *method) {
    const char *name(sel_getName(method_getName(method)));
    if (strchr(name, ':') != NULL)
        return;

    const char *type(method_getTypeEncoding(method));
    if (type == NULL || *type == '\0' || *type == 'v')
        return;

    JSPropertyNameAccumulatorAddName(names, CYJSString(name));
}

static void Instance_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    CYPool pool;
    Class _class(object_getClass(self));

#ifdef __APPLE__
    {
        unsigned int size;
        objc_property_t *data(class_copyPropertyList(_class, &size));
        for (size_t i(0); i != size; ++i)
            JSPropertyNameAccumulatorAddName(names, CYJSString(property_getName(data[i])));
        free(data);
    }
#endif

    if (CYHasImplicitProperties(_class))
        for (Class current(_class); current != nil; current = class_getSuperclass(current)) {
#if OBJC_API_VERSION >= 2
            unsigned int size;
            objc_method **data(class_copyMethodList(current, &size));
            for (size_t i(0); i != size; ++i)
                Instance_getPropertyNames_message(names, data[i]);
            free(data);
#else
            for (objc_method_list *methods(current->methods); methods != NULL; methods = methods->method_next)
                for (int i(0); i != methods->method_count; ++i)
                    Instance_getPropertyNames_message(names, &methods->method_list[i]);
#endif
        }

    CYPoolTry {
        // XXX: this is an evil hack to deal with NSProxy; fix elsewhere
        if (CYImplements(self, _class, @selector(cy$getPropertyNames:inContext:)))
            [self cy$getPropertyNames:names inContext:context];
    } CYPoolCatch()
}

static JSObjectRef Instance_callAsConstructor(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    JSObjectRef value(Instance::Make(context, [internal->GetValue() alloc], Instance::Uninitialized));
    return value;
} CYCatch }

static JSValueRef Instance_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());

    if (![self isKindOfClass:NSBlock_])
        CYThrow("non-NSBlock object is not a function");
    // XXX: replace above logic with the following assertion
    //_assert([self isKindOfClass:NSBlock_]);
    // to do this, make it so FunctionInstance_ is the class of blocks
    // to do /that/, generalize the various "is exactly Instance_" checks
    // then, move Instance_callAsFunction to only be on FunctionInstance

    struct BlockDescriptor1 {
        unsigned long int reserved;
        unsigned long int size;
    };

    struct BlockDescriptor2 {
        void (*copy_helper)(void *dst, void *src);
        void (*dispose_helper)(void *src);
    };

    struct BlockDescriptor3 {
        const char *signature;
        const char *layout;
    };

    struct BlockLiteral {
        Class isa;
        int flags;
        int reserved;
        void (*invoke)(void *, ...);
        void *descriptor;
    } *literal = reinterpret_cast<BlockLiteral *>(self);

    enum {
        BLOCK_DEALLOCATING = 0x0001,
        BLOCK_REFCOUNT_MASK = 0xfffe,
        BLOCK_NEEDS_FREE = 1 << 24,
        BLOCK_HAS_COPY_DISPOSE = 1 << 25,
        BLOCK_HAS_CTOR = 1 << 26,
        BLOCK_IS_GC = 1 << 27,
        BLOCK_IS_GLOBAL = 1 << 28,
        BLOCK_HAS_STRET = 1 << 29,
        BLOCK_HAS_SIGNATURE = 1 << 30,
    };

    if ((literal->flags & BLOCK_HAS_SIGNATURE) != 0) {
        uint8_t *descriptor(reinterpret_cast<uint8_t *>(literal->descriptor));
        descriptor += sizeof(BlockDescriptor1);
        if ((literal->flags & BLOCK_HAS_COPY_DISPOSE) != 0)
            descriptor += sizeof(BlockDescriptor2);
        BlockDescriptor3 *descriptor3(reinterpret_cast<BlockDescriptor3 *>(descriptor));

        if (const char *type = descriptor3->signature) {
            CYPool pool;

            void *setup[1];
            setup[0] = &self;

            sig::Signature signature;
            sig::Parse(pool, &signature, type, &Structor_);

            ffi_cif cif;
            sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);

            void (*function)() = reinterpret_cast<void (*)()>(literal->invoke);
            return CYCallFunction(pool, context, 1, setup, count, arguments, false, exception, &signature, &cif, function);
        }
    }

    if (count != 0)
        CYThrow("NSBlock without signature field passed arguments");

    CYPoolTry {
        [self invoke];
    } CYPoolCatch(NULL);

    return NULL;
} CYCatch }

static bool Instance_hasInstance(JSContextRef context, JSObjectRef constructor, JSValueRef instance, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate((JSObjectRef) constructor)));
    Class _class(internal->GetValue());
    if (!CYIsClass(_class))
        return false;

    if (CYJSValueIsNSObject(context, instance)) {
        Instance *linternal(reinterpret_cast<Instance *>(JSObjectGetPrivate((JSObjectRef) instance)));
        // XXX: this isn't always safe
        return [linternal->GetValue() isKindOfClass:_class];
    }

    return false;
} CYCatch }

static JSValueRef Instance_box_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count == 0)
        throw CYJSError(context, "incorrect number of arguments to Instance");
    CYPool pool;
    id value(CYCastNSObject(pool, context, arguments[0]));
    if (value == nil)
        value = [NSNull null];
    return CYCastJSValue(context, [value cy$box]);
} CYCatch }

static bool Internal_hasProperty(JSContextRef context, JSObjectRef object, JSStringRef property) {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    const char *name(CYPoolCString(pool, context, property));

    if (object_getInstanceVariable(self, name, NULL) != NULL)
        return true;

    return false;
}

static JSValueRef Internal_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    const char *name(CYPoolCString(pool, context, property));

    if (objc_ivar *ivar = object_getInstanceVariable(self, name, NULL)) {
        Type_privateData type(pool, ivar_getTypeEncoding(ivar));
        // XXX: if this fails and throws an exception the person we are throwing it to gets the wrong exception
        return CYFromFFI(context, type.type_, type.GetFFI(), reinterpret_cast<uint8_t *>(self) + ivar_getOffset(ivar));
    }

    return NULL;
} CYCatch }

static bool Internal_setProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef value, JSValueRef *exception) { CYTry {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    const char *name(CYPoolCString(pool, context, property));

    if (objc_ivar *ivar = object_getInstanceVariable(self, name, NULL)) {
        Type_privateData type(pool, ivar_getTypeEncoding(ivar));
        CYPoolFFI(pool, context, type.type_, type.GetFFI(), reinterpret_cast<uint8_t *>(self) + ivar_getOffset(ivar), value);
        return true;
    }

    return false;
} CYCatch }

static void Internal_getPropertyNames_(Class _class, JSPropertyNameAccumulatorRef names) {
    if (Class super = class_getSuperclass(_class))
        Internal_getPropertyNames_(super, names);

#if OBJC_API_VERSION >= 2
    unsigned int size;
    objc_ivar **data(class_copyIvarList(_class, &size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(ivar_getName(data[i])));
    free(data);
#else
    if (objc_ivar_list *ivars = _class->ivars)
        for (int i(0); i != ivars->ivar_count; ++i)
            JSPropertyNameAccumulatorAddName(names, CYJSString(ivar_getName(&ivars->ivar_list[i])));
#endif
}

static void Internal_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    CYPool pool;

    id self(internal->GetValue());
    Class _class(object_getClass(self));

    Internal_getPropertyNames_(_class, names);
}

static JSValueRef Internal_callAsFunction_$cya(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    Internal *internal(reinterpret_cast<Internal *>(JSObjectGetPrivate(object)));
    return internal->GetOwner();
}

static JSValueRef ObjectiveC_Classes_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    NSString *name(CYCastNSString(pool, context, property));
    if (Class _class = NSClassFromString(name))
        return CYMakeInstance(context, _class, true);
    return NULL;
} CYCatch }

static void ObjectiveC_Classes_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
#ifdef __APPLE__
    size_t size(objc_getClassList(NULL, 0));
    Class *data(reinterpret_cast<Class *>(malloc(sizeof(Class) * size)));

  get:
    size_t writ(objc_getClassList(data, size));
    if (size < writ) {
        size = writ;
        if (Class *copy = reinterpret_cast<Class *>(realloc(data, sizeof(Class) * writ))) {
            data = copy;
            goto get;
        } else goto done;
    }

    for (size_t i(0); i != writ; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(class_getName(data[i])));

  done:
    free(data);
#else
    void *state(NULL);
    while (Class _class = objc_next_class(&state))
        JSPropertyNameAccumulatorAddName(names, CYJSString(class_getName(_class)));
#endif
}

#if OBJC_API_VERSION >= 2
static JSValueRef ObjectiveC_Image_Classes_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    const char *internal(reinterpret_cast<const char *>(JSObjectGetPrivate(object)));

    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));
    unsigned int size;
    const char **data(objc_copyClassNamesForImage(internal, &size));
    JSValueRef value;
    for (size_t i(0); i != size; ++i)
        if (strcmp(name, data[i]) == 0) {
            if (Class _class = objc_getClass(name)) {
                value = CYMakeInstance(context, _class, true);
                goto free;
            } else
                break;
        }
    value = NULL;
  free:
    free(data);
    return value;
} CYCatch }

static void ObjectiveC_Image_Classes_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    const char *internal(reinterpret_cast<const char *>(JSObjectGetPrivate(object)));
    unsigned int size;
    const char **data(objc_copyClassNamesForImage(internal, &size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(data[i]));
    free(data);
}

static JSValueRef ObjectiveC_Images_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));
    unsigned int size;
    const char **data(objc_copyImageNames(&size));
    for (size_t i(0); i != size; ++i)
        if (strcmp(name, data[i]) == 0) {
            name = data[i];
            goto free;
        }
    name = NULL;
  free:
    free(data);
    if (name == NULL)
        return NULL;
    JSObjectRef value(JSObjectMake(context, NULL, NULL));
    CYSetProperty(context, value, CYJSString("classes"), JSObjectMake(context, ObjectiveC_Image_Classes_, const_cast<char *>(name)));
    return value;
} CYCatch }

static void ObjectiveC_Images_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    unsigned int size;
    const char **data(objc_copyImageNames(&size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(data[i]));
    free(data);
}
#endif

static JSValueRef ObjectiveC_Protocols_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    const char *name(CYPoolCString(pool, context, property));
    if (Protocol *protocol = objc_getProtocol(name))
        return CYMakeInstance(context, protocol, true);
    return NULL;
} CYCatch }

static void ObjectiveC_Protocols_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
#if OBJC_API_VERSION >= 2
    unsigned int size;
    Protocol **data(objc_copyProtocolList(&size));
    for (size_t i(0); i != size; ++i)
        JSPropertyNameAccumulatorAddName(names, CYJSString(protocol_getName(data[i])));
    free(data);
#else
    // XXX: fix this!
#endif
}

static JSValueRef ObjectiveC_Constants_getProperty(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    CYPool pool;
    CYUTF8String name(CYPoolUTF8String(pool, context, property));
    if (name == "nil")
        return Instance::Make(context, nil);
    return NULL;
} CYCatch }

static void ObjectiveC_Constants_getPropertyNames(JSContextRef context, JSObjectRef object, JSPropertyNameAccumulatorRef names) {
    JSPropertyNameAccumulatorAddName(names, CYJSString("nil"));
}

#ifdef __APPLE__
static bool stret(ffi_type *ffi_type) {
    return ffi_type->type == FFI_TYPE_STRUCT && (
        ffi_type->size > OBJC_MAX_STRUCT_BY_VALUE ||
        struct_forward_array[ffi_type->size] != 0
    );
}
#endif

JSValueRef CYSendMessage(apr_pool_t *pool, JSContextRef context, id self, Class _class, SEL _cmd, size_t count, const JSValueRef arguments[], bool initialize, JSValueRef *exception) { CYTry {
    const char *type;

    if (_class == NULL)
        _class = object_getClass(self);

    IMP imp;

    if (objc_method *method = class_getInstanceMethod(_class, _cmd)) {
        imp = method_getImplementation(method);
        type = method_getTypeEncoding(method);
    } else {
        imp = NULL;

        CYPoolTry {
            NSMethodSignature *method([self methodSignatureForSelector:_cmd]);
            if (method == nil)
                throw CYJSError(context, "unrecognized selector %s sent to object %p", sel_getName(_cmd), self);
            type = CYPoolCString(pool, context, [method _typeString]);
        } CYPoolCatch(NULL)
    }

    void *setup[2];
    setup[0] = &self;
    setup[1] = &_cmd;

    sig::Signature signature;
    sig::Parse(pool, &signature, type, &Structor_);

    size_t used(count + 3);
    if (used > signature.count) {
        sig::Element *elements(new (pool) sig::Element[used]);
        memcpy(elements, signature.elements, used * sizeof(sig::Element));

        for (size_t index(signature.count); index != used; ++index) {
            sig::Element *element(&elements[index]);
            element->name = NULL;
            element->offset = _not(size_t);

            sig::Type *type(new (pool) sig::Type);
            memset(type, 0, sizeof(*type));
            type->primitive = sig::object_P;
            element->type = type;
        }

        signature.elements = elements;
        signature.count = used;
    }

    ffi_cif cif;
    sig::sig_ffi_cif(pool, &sig::ObjectiveC, &signature, &cif);

    if (imp == NULL) {
#ifdef __APPLE__
        if (stret(cif.rtype))
            imp = class_getMethodImplementation_stret(_class, _cmd);
        else
            imp = class_getMethodImplementation(_class, _cmd);
#else
        objc_super super = {self, _class};
        imp = objc_msg_lookup_super(&super, _cmd);
#endif
    }

    void (*function)() = reinterpret_cast<void (*)()>(imp);
    return CYCallFunction(pool, context, 2, setup, count, arguments, initialize, exception, &signature, &cif, function);
} CYCatch }

static JSValueRef $objc_msgSend(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count < 2)
        throw CYJSError(context, "too few arguments to objc_msgSend");

    CYPool pool;

    bool uninitialized;

    id self;
    SEL _cmd;
    Class _class;

    if (JSValueIsObjectOfClass(context, arguments[0], Super_)) {
        cy::Super *internal(reinterpret_cast<cy::Super *>(JSObjectGetPrivate((JSObjectRef) arguments[0])));
        self = internal->GetValue();
        _class = internal->class_;;
        uninitialized = false;
    } else if (CYJSValueIsNSObject(context, arguments[0])) {
        Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate((JSObjectRef) arguments[0])));
        self = internal->GetValue();
        _class = nil;
        uninitialized = internal->IsUninitialized();
        if (uninitialized)
            internal->value_ = nil;
    } else {
        self = CYCastNSObject(pool, context, arguments[0]);
        _class = nil;
        uninitialized = false;
    }

    if (self == nil)
        return CYJSNull(context);

    _cmd = CYCastSEL(context, arguments[1]);

    return CYSendMessage(pool, context, self, _class, _cmd, count - 2, arguments + 2, uninitialized, exception);
} CYCatch }

static JSValueRef Selector_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    JSValueRef setup[count + 2];
    setup[0] = _this;
    setup[1] = object;
    memcpy(setup + 2, arguments, sizeof(JSValueRef) * count);
    return $objc_msgSend(context, NULL, NULL, count + 2, setup, exception);
}

static JSValueRef Message_callAsFunction(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYPool pool;
    Message_privateData *internal(reinterpret_cast<Message_privateData *>(JSObjectGetPrivate(object)));

    // XXX: handle Instance::Uninitialized?
    id self(CYCastNSObject(pool, context, _this));

    void *setup[2];
    setup[0] = &self;
    setup[1] = &internal->sel_;

    return CYCallFunction(pool, context, 2, setup, count, arguments, false, exception, &internal->signature_, &internal->cif_, internal->GetValue());
}

static JSObjectRef Super_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 2)
        throw CYJSError(context, "incorrect number of arguments to Super constructor");
    CYPool pool;
    id self(CYCastNSObject(pool, context, arguments[0]));
    Class _class(CYCastClass(pool, context, arguments[1]));
    return cy::Super::Make(context, self, _class);
} CYCatch }

static JSObjectRef Selector_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 1)
        throw CYJSError(context, "incorrect number of arguments to Selector constructor");
    CYPool pool;
    const char *name(CYPoolCString(pool, context, arguments[0]));
    return CYMakeSelector(context, sel_registerName(name));
} CYCatch }

static JSObjectRef Instance_new(JSContextRef context, JSObjectRef object, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count > 1)
        throw CYJSError(context, "incorrect number of arguments to Instance constructor");
    id self(count == 0 ? nil : CYCastPointer<id>(context, arguments[0]));
    return CYMakeInstance(context, self, false);
} CYCatch }

static JSValueRef CYValue_getProperty_value(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    CYValue *internal(reinterpret_cast<CYValue *>(JSObjectGetPrivate(object)));
    return CYCastJSValue(context, reinterpret_cast<uintptr_t>(internal->value_));
}

static JSValueRef CYValue_callAsFunction_$cya(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    CYValue *internal(reinterpret_cast<CYValue *>(JSObjectGetPrivate(_this)));
    Type_privateData *typical(internal->GetType());

    sig::Type *type;
    ffi_type *ffi;

    if (typical == NULL) {
        type = NULL;
        ffi = NULL;
    } else {
        type = typical->type_;
        ffi = typical->ffi_;
    }

    return CYMakePointer(context, &internal->value_, _not(size_t), type, ffi, object);
}

static JSValueRef Instance_getProperty_constructor(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    return Instance::Make(context, (id) object_getClass(internal->GetValue()));
}

static JSValueRef Instance_getProperty_prototype(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) { CYTry {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());
    if (!CYIsClass(self))
        return CYJSUndefined(context);
    return CYGetClassPrototype(context, self);
} CYCatch }

static JSValueRef Instance_getProperty_messages(JSContextRef context, JSObjectRef object, JSStringRef property, JSValueRef *exception) {
    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(object)));
    id self(internal->GetValue());
    if (!CYIsClass(self))
        return CYJSUndefined(context);
    return Messages::Make(context, (Class) self);
}

static JSValueRef Instance_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!CYJSValueIsNSObject(context, _this))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));
    return CYCastJSValue(context, CYJSString(context, CYCastNSCYON(internal->GetValue(), false)));
} CYCatch }

static JSValueRef Instance_callAsFunction_toJSON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!CYJSValueIsNSObject(context, _this))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));
    id value(internal->GetValue());

    CYPoolTry {
        NSString *key;
        if (count == 0)
            key = nil;
        else
            key = CYCastNSString(NULL, context, CYJSString(context, arguments[0]));

        if (!CYImplements(value, object_getClass(value), @selector(cy$toJSON:inContext:)))
            return CYJSUndefined(context);
        else if (JSValueRef json = [value cy$toJSON:key inContext:context])
            return json;
        else
            return CYCastJSValue(context, CYJSString(context, [value description]));
    } CYPoolCatch(NULL)
} CYCatch return /*XXX*/ NULL; }

static JSValueRef Instance_callAsFunction_valueOf(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!CYJSValueIsNSObject(context, _this))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));
    id value(internal->GetValue());

    if (![value respondsToSelector:@selector(cy$valueOfInContext:)])
        return _this;

    if (JSValueRef result = [value cy$valueOfInContext:context])
        return result;

    return _this;
} CYCatch return /*XXX*/ NULL; }

static JSValueRef Instance_callAsFunction_toPointer(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!CYJSValueIsNSObject(context, _this))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));
    // XXX: but... but... THIS ISN'T A POINTER! :(
    return CYCastJSValue(context, reinterpret_cast<uintptr_t>(internal->GetValue()));
} CYCatch return /*XXX*/ NULL; }

static JSValueRef Instance_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (!CYJSValueIsNSObject(context, _this))
        return NULL;

    Instance *internal(reinterpret_cast<Instance *>(JSObjectGetPrivate(_this)));
    id value(internal->GetValue());

    if (value == nil)
        return CYCastJSValue(context, "nil");

    CYPoolTry {
        // XXX: this seems like a stupid implementation; what if it crashes? why not use the CYONifier backend?
        return CYCastJSValue(context, CYJSString(context, [value description]));
    } CYPoolCatch(NULL)
} CYCatch return /*XXX*/ NULL; }

static JSValueRef Selector_callAsFunction_toString(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
    return CYCastJSValue(context, sel_getName(internal->GetValue()));
} CYCatch }

static JSValueRef Selector_callAsFunction_toJSON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) {
    return Selector_callAsFunction_toString(context, object, _this, count, arguments, exception);
}

static JSValueRef Selector_callAsFunction_toCYON(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
    const char *name(sel_getName(internal->GetValue()));

    CYPoolTry {
        NSString *string([NSString stringWithFormat:@"@selector(%s)", name]);
        return CYCastJSValue(context, CYJSString(context, string));
    } CYPoolCatch(NULL)
} CYCatch return /*XXX*/ NULL; }

static JSValueRef Selector_callAsFunction_type(JSContextRef context, JSObjectRef object, JSObjectRef _this, size_t count, const JSValueRef arguments[], JSValueRef *exception) { CYTry {
    if (count != 1)
        throw CYJSError(context, "incorrect number of arguments to Selector.type");

    CYPool pool;
    Selector_privateData *internal(reinterpret_cast<Selector_privateData *>(JSObjectGetPrivate(_this)));
    SEL sel(internal->GetValue());

    objc_method *method;
    if (Class _class = CYCastClass(pool, context, arguments[0]))
        method = class_getInstanceMethod(_class, sel);
    else
        method = NULL;

    if (const char *type = CYPoolTypeEncoding(pool, context, sel, method))
        return CYCastJSValue(context, CYJSString(type));

    return CYJSNull(context);
} CYCatch }

static JSStaticValue Selector_staticValues[2] = {
    {"value", &CYValue_getProperty_value, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};

static JSStaticValue Instance_staticValues[5] = {
    {"constructor", &Instance_getProperty_constructor, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"messages", &Instance_getProperty_messages, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"prototype", &Instance_getProperty_prototype, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"value", &CYValue_getProperty_value, NULL, kJSPropertyAttributeReadOnly | kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, NULL, 0}
};

static JSStaticFunction Instance_staticFunctions[7] = {
    {"$cya", &CYValue_callAsFunction_$cya, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toCYON", &Instance_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &Instance_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"valueOf", &Instance_callAsFunction_valueOf, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toPointer", &Instance_callAsFunction_toPointer, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toString", &Instance_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Internal_staticFunctions[2] = {
    {"$cya", &Internal_callAsFunction_$cya, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

static JSStaticFunction Selector_staticFunctions[5] = {
    {"toCYON", &Selector_callAsFunction_toCYON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toJSON", &Selector_callAsFunction_toJSON, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"toString", &Selector_callAsFunction_toString, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {"type", &Selector_callAsFunction_type, kJSPropertyAttributeDontEnum | kJSPropertyAttributeDontDelete},
    {NULL, NULL, 0}
};

#ifdef __APPLE__
JSValueRef NSCFType$cy$toJSON$inContext$(id self, SEL sel, JSValueRef key, JSContextRef context) { CYObjectiveTry_(context) {
    return CYCastJSValue(context, [(NSString *) CFCopyDescription((CFTypeRef) self) autorelease]);
} CYObjectiveCatch }
#endif

void CYObjectiveC_Initialize() { /*XXX*/ JSContextRef context(NULL); CYPoolTry {
    $objc_setAssociatedObject = reinterpret_cast<void (*)(id, void *, id value, objc_AssociationPolicy)>(dlsym(RTLD_DEFAULT, "objc_setAssociatedObject"));
    $objc_getAssociatedObject = reinterpret_cast<id (*)(id, void *)>(dlsym(RTLD_DEFAULT, "objc_getAssociatedObject"));
    $objc_removeAssociatedObjects = reinterpret_cast<void (*)(id)>(dlsym(RTLD_DEFAULT, "objc_removeAssociatedObjects"));

    apr_pool_t *pool(CYGetGlobalPool());

    Object_type = new(pool) Type_privateData("@");
    Selector_type = new(pool) Type_privateData(":");

#ifdef __APPLE__
    // XXX: apparently, iOS now has both of these
    NSCFBoolean_ = objc_getClass("__NSCFBoolean");
    if (NSCFBoolean_ == nil)
        NSCFBoolean_ = objc_getClass("NSCFBoolean");

    NSCFType_ = objc_getClass("NSCFType");
    NSGenericDeallocHandler_ = objc_getClass("__NSGenericDeallocHandler");
    NSMessageBuilder_ = objc_getClass("NSMessageBuilder");
    NSZombie_ = objc_getClass("_NSZombie_");
#else
    NSBoolNumber_ = objc_getClass("NSBoolNumber");
#endif

    NSArray_ = objc_getClass("NSArray");
    NSBlock_ = objc_getClass("NSBlock");
    NSDictionary_ = objc_getClass("NSDictionary");
    NSString_ = objc_getClass("NSString");
    Object_ = objc_getClass("Object");

    JSClassDefinition definition;

    definition = kJSClassDefinitionEmpty;
    definition.className = "Instance";
    definition.staticValues = Instance_staticValues;
    definition.staticFunctions = Instance_staticFunctions;
    definition.hasProperty = &Instance_hasProperty;
    definition.getProperty = &Instance_getProperty;
    definition.setProperty = &Instance_setProperty;
    definition.deleteProperty = &Instance_deleteProperty;
    definition.getPropertyNames = &Instance_getPropertyNames;
    definition.callAsConstructor = &Instance_callAsConstructor;
    definition.callAsFunction = &Instance_callAsFunction;
    definition.hasInstance = &Instance_hasInstance;
    definition.finalize = &CYFinalize;
    Instance_ = JSClassCreate(&definition);

    definition.className = "ArrayInstance";
    ArrayInstance_ = JSClassCreate(&definition);

    definition.className = "ObjectInstance";
    ObjectInstance_ = JSClassCreate(&definition);

    definition.className = "StringInstance";
    StringInstance_ = JSClassCreate(&definition);

    definition.className = "FunctionInstance";
    FunctionInstance_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Internal";
    definition.staticFunctions = Internal_staticFunctions;
    definition.hasProperty = &Internal_hasProperty;
    definition.getProperty = &Internal_getProperty;
    definition.setProperty = &Internal_setProperty;
    definition.getPropertyNames = &Internal_getPropertyNames;
    definition.finalize = &CYFinalize;
    Internal_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Message";
    definition.staticFunctions = cy::Functor::StaticFunctions;
    definition.callAsFunction = &Message_callAsFunction;
    definition.finalize = &CYFinalize;
    Message_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Messages";
    definition.hasProperty = &Messages_hasProperty;
    definition.getProperty = &Messages_getProperty;
    definition.setProperty = &Messages_setProperty;
#if 0 && OBJC_API_VERSION < 2
    definition.deleteProperty = &Messages_deleteProperty;
#endif
    definition.getPropertyNames = &Messages_getPropertyNames;
    definition.finalize = &CYFinalize;
    Messages_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Selector";
    definition.staticValues = Selector_staticValues;
    definition.staticFunctions = Selector_staticFunctions;
    definition.callAsFunction = &Selector_callAsFunction;
    definition.finalize = &CYFinalize;
    Selector_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "Super";
    definition.staticFunctions = Internal_staticFunctions;
    definition.finalize = &CYFinalize;
    Super_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Classes";
    definition.getProperty = &ObjectiveC_Classes_getProperty;
    definition.getPropertyNames = &ObjectiveC_Classes_getPropertyNames;
    ObjectiveC_Classes_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Constants";
    definition.getProperty = &ObjectiveC_Constants_getProperty;
    definition.getPropertyNames = &ObjectiveC_Constants_getPropertyNames;
    ObjectiveC_Constants_ = JSClassCreate(&definition);

#if OBJC_API_VERSION >= 2
    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Images";
    definition.getProperty = &ObjectiveC_Images_getProperty;
    definition.getPropertyNames = &ObjectiveC_Images_getPropertyNames;
    ObjectiveC_Images_ = JSClassCreate(&definition);

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Image::Classes";
    definition.getProperty = &ObjectiveC_Image_Classes_getProperty;
    definition.getPropertyNames = &ObjectiveC_Image_Classes_getPropertyNames;
    ObjectiveC_Image_Classes_ = JSClassCreate(&definition);
#endif

    definition = kJSClassDefinitionEmpty;
    definition.className = "ObjectiveC::Protocols";
    definition.getProperty = &ObjectiveC_Protocols_getProperty;
    definition.getPropertyNames = &ObjectiveC_Protocols_getPropertyNames;
    ObjectiveC_Protocols_ = JSClassCreate(&definition);

#ifdef __APPLE__
    class_addMethod(NSCFType_, @selector(cy$toJSON:inContext:), reinterpret_cast<IMP>(&NSCFType$cy$toJSON$inContext$), "^{OpaqueJSValue=}16@0:4@8^{OpaqueJSContext=}12");
#endif
} CYPoolCatch() }

void CYObjectiveC_SetupContext(JSContextRef context) { CYPoolTry {
    JSObjectRef global(CYGetGlobalObject(context));
    JSObjectRef cy(CYCastJSObject(context, CYGetProperty(context, global, cy_s)));
    JSObjectRef cycript(CYCastJSObject(context, CYGetProperty(context, global, CYJSString("Cycript"))));
    JSObjectRef all(CYCastJSObject(context, CYGetProperty(context, cycript, CYJSString("all"))));
    JSObjectRef alls(CYCastJSObject(context, CYGetProperty(context, cycript, CYJSString("alls"))));

    JSObjectRef ObjectiveC(JSObjectMake(context, NULL, NULL));
    CYSetProperty(context, cycript, CYJSString("ObjectiveC"), ObjectiveC);

    JSObjectRef protocols(JSObjectMake(context, ObjectiveC_Protocols_, NULL));
    CYSetProperty(context, ObjectiveC, CYJSString("protocols"), protocols);
    CYArrayPush(context, alls, protocols);

    JSObjectRef classes(JSObjectMake(context, ObjectiveC_Classes_, NULL));
    CYSetProperty(context, ObjectiveC, CYJSString("classes"), classes);
    CYArrayPush(context, alls, classes);

    JSObjectRef constants(JSObjectMake(context, ObjectiveC_Constants_, NULL));
    CYSetProperty(context, ObjectiveC, CYJSString("constants"), constants);
    CYArrayPush(context, alls, constants);

#if OBJC_API_VERSION >= 2
    CYSetProperty(context, ObjectiveC, CYJSString("images"), JSObjectMake(context, ObjectiveC_Images_, NULL));
#endif

    JSObjectRef Instance(JSObjectMakeConstructor(context, Instance_, &Instance_new));
    JSObjectRef Message(JSObjectMakeConstructor(context, Message_, NULL));
    JSObjectRef Selector(JSObjectMakeConstructor(context, Selector_, &Selector_new));
    JSObjectRef Super(JSObjectMakeConstructor(context, Super_, &Super_new));

    JSObjectRef Instance_prototype(CYCastJSObject(context, CYGetProperty(context, Instance, prototype_s)));
    CYSetProperty(context, cy, CYJSString("Instance_prototype"), Instance_prototype);

    JSObjectRef ArrayInstance(JSObjectMakeConstructor(context, ArrayInstance_, NULL));
    JSObjectRef ArrayInstance_prototype(CYCastJSObject(context, CYGetProperty(context, ArrayInstance, prototype_s)));
    CYSetProperty(context, cy, CYJSString("ArrayInstance_prototype"), ArrayInstance_prototype);
    JSObjectRef Array_prototype(CYGetCachedObject(context, CYJSString("Array_prototype")));
    JSObjectSetPrototype(context, ArrayInstance_prototype, Array_prototype);

    JSObjectRef FunctionInstance(JSObjectMakeConstructor(context, FunctionInstance_, NULL));
    JSObjectRef FunctionInstance_prototype(CYCastJSObject(context, CYGetProperty(context, FunctionInstance, prototype_s)));
    CYSetProperty(context, cy, CYJSString("FunctionInstance_prototype"), FunctionInstance_prototype);
    JSObjectRef Function_prototype(CYGetCachedObject(context, CYJSString("Function_prototype")));
    JSObjectSetPrototype(context, FunctionInstance_prototype, Function_prototype);

    JSObjectRef ObjectInstance(JSObjectMakeConstructor(context, ObjectInstance_, NULL));
    JSObjectRef ObjectInstance_prototype(CYCastJSObject(context, CYGetProperty(context, ObjectInstance, prototype_s)));
    CYSetProperty(context, cy, CYJSString("ObjectInstance_prototype"), ObjectInstance_prototype);
    JSObjectRef Object_prototype(CYGetCachedObject(context, CYJSString("Object_prototype")));
    JSObjectSetPrototype(context, ObjectInstance_prototype, Object_prototype);

    JSObjectRef StringInstance(JSObjectMakeConstructor(context, StringInstance_, NULL));
    JSObjectRef StringInstance_prototype(CYCastJSObject(context, CYGetProperty(context, StringInstance, prototype_s)));
    CYSetProperty(context, cy, CYJSString("StringInstance_prototype"), StringInstance_prototype);
    JSObjectRef String_prototype(CYGetCachedObject(context, CYJSString("String_prototype")));
    JSObjectSetPrototype(context, StringInstance_prototype, String_prototype);

    CYSetProperty(context, cycript, CYJSString("Instance"), Instance);
    CYSetProperty(context, cycript, CYJSString("Selector"), Selector);
    CYSetProperty(context, cycript, CYJSString("Super"), Super);

    JSObjectRef box(JSObjectMakeFunctionWithCallback(context, CYJSString("box"), &Instance_box_callAsFunction));
    CYSetProperty(context, Instance, CYJSString("box"), box);

#if defined(__APPLE__) && defined(__arm__) && 0
    CYSetProperty(context, all, CYJSString("objc_registerClassPair"), &objc_registerClassPair_, kJSPropertyAttributeDontEnum);
#endif

    CYSetProperty(context, all, CYJSString("objc_msgSend"), &$objc_msgSend, kJSPropertyAttributeDontEnum);

    JSObjectSetPrototype(context, CYCastJSObject(context, CYGetProperty(context, Message, prototype_s)), Function_prototype);
    JSObjectSetPrototype(context, CYCastJSObject(context, CYGetProperty(context, Selector, prototype_s)), Function_prototype);
} CYPoolCatch() }

static CYHooks CYObjectiveCHooks = {
    &CYObjectiveC_ExecuteStart,
    &CYObjectiveC_ExecuteEnd,
    &CYObjectiveC_CallFunction,
    &CYObjectiveC_Initialize,
    &CYObjectiveC_SetupContext,
    &CYObjectiveC_PoolFFI,
    &CYObjectiveC_FromFFI,
};

struct CYObjectiveC {
    CYObjectiveC() {
        hooks_ = &CYObjectiveCHooks;
        // XXX: evil magic juju to make this actually take effect on a Mac when compiled with autoconf/libtool doom!
        _assert(hooks_ != NULL);
    }
} CYObjectiveC;
