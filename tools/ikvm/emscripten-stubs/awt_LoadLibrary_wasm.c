/*
 * awt_LoadLibrary_wasm.c
 *
 * Wasm replacement for solaris/native/sun/awt/awt_LoadLibrary.c.
 *
 * The stock awt_LoadLibrary.c does three things in libawt.so's JNI_OnLoad:
 *   1. Sets the sun.font.fontmanager system property.
 *   2. Calls back into Java's System.load(".../libawt_headless.so") to
 *      chain-load the headless toolkit library.
 *   3. dlopen()s the same path to obtain a handle for later dlsym lookups.
 *
 * Neither (2) nor (3) makes sense in a static-link wasm build:
 *   - libawt_headless's only real native code (AWTIsHeadless returning true,
 *     and a no-op JNI_OnLoad) is merged into this same libawt.a.
 *   - There is no dynamic loader; dlopen returns NULL with -sMAIN_MODULE=0.
 *
 * So we keep (1) and ditch (2) and (3). AWTIsHeadless is implemented by
 * calling back into java.awt.GraphicsEnvironment.isHeadless() — same behavior
 * as the stock file, just without the toolkit-selection dance that follows.
 */

#include <jni.h>
#include <jni_util.h>

/* Renamed from `jvm` to avoid colliding with the `jvm` global in libjpeg's
 * jpegdecoder.c (also patched, → __libjpeg_jvm) and liblwjgl3's common_tools.c.
 * Other libawt TUs (img_colors.c) reference this via the same renamed name
 * — see the matching openjdk.patch hunk for img_colors.c. */
JavaVM *__libawt_jvm;

JNIEXPORT jboolean JNICALL AWTIsHeadless() {
    static JNIEnv *env = NULL;
    static jboolean isHeadless;
    jmethodID headlessFn;
    jclass graphicsEnvClass;

    if (env == NULL) {
        env = (JNIEnv *)JNU_GetEnv(__libawt_jvm, JNI_VERSION_1_2);
        graphicsEnvClass = (*env)->FindClass(env, "java/awt/GraphicsEnvironment");
        if (graphicsEnvClass == NULL) {
            return JNI_TRUE;
        }
        headlessFn = (*env)->GetStaticMethodID(env, graphicsEnvClass,
                                               "isHeadless", "()Z");
        if (headlessFn == NULL) {
            return JNI_TRUE;
        }
        isHeadless = (*env)->CallStaticBooleanMethod(env, graphicsEnvClass,
                                                     headlessFn);
    }
    return isHeadless;
}

#define CHECK_EXCEPTION_FATAL(env, message) \
    if ((*env)->ExceptionCheck(env)) { \
        (*env)->ExceptionClear(env); \
        (*env)->FatalError(env, message); \
    }

/* Renamed from JNI_OnLoad to avoid colliding with libiava/libjpeg/liblcms at
 * static-link time; gen-static-libs.py re-keys __lib<NAME>_JNI_OnLoad back to
 * "JNI_OnLoad" in this lib's per-library symbol table. */
JNIEXPORT jint JNICALL
__libawt_JNI_OnLoad(JavaVM *vm, void *reserved)
{
    JNIEnv *env;
    jstring fmProp, fmanager;

    __libawt_jvm = vm;
    env = (JNIEnv *)JNU_GetEnv(vm, JNI_VERSION_1_2);

    fmProp = (*env)->NewStringUTF(env, "sun.font.fontmanager");
    CHECK_EXCEPTION_FATAL(env, "Could not allocate font manager property");
    fmanager = (*env)->NewStringUTF(env, "sun.awt.X11FontManager");
    CHECK_EXCEPTION_FATAL(env, "Could not allocate font manager name");

    if (fmanager && fmProp) {
        JNU_CallStaticMethodByName(env, NULL, "java/lang/System", "setProperty",
                                   "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
                                   fmProp, fmanager);
        CHECK_EXCEPTION_FATAL(env, "Could not set font manager property");
    }

    if (fmProp)   (*env)->DeleteLocalRef(env, fmProp);
    if (fmanager) (*env)->DeleteLocalRef(env, fmanager);

    return JNI_VERSION_1_2;
}

/*
 * sdtjmplay (CDE Java Media Framework) ABI compatibility shim.
 * The stock libawt.so reflects this call into libawt_xawt; in headless wasm
 * there is no X11 toolkit at all, so this is just a no-op.
 */
JNIEXPORT void JNICALL
Java_sun_awt_motif_XsessionWMcommand(JNIEnv *env, jobject this_,
                                     jobject frame, jstring jcommand)
{
    (void)env; (void)this_; (void)frame; (void)jcommand;
}

JNIEXPORT void JNICALL
Java_sun_awt_motif_XsessionWMcommand_New(JNIEnv *env, jobjectArray jargv)
{
    (void)env; (void)jargv;
}
