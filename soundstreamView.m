#import "soundstreamView.h"

#ifndef GL_SILENCE_DEPRECATION
#define GL_SILENCE_DEPRECATION
#endif
#import <OpenGL/gl.h>
#import <OpenGL/glu.h>

#define MAX_STREAMS         1
#define PARTICLES_PER_STREAM 900
#define TOTAL_PARTICLES     (MAX_STREAMS * PARTICLES_PER_STREAM)

static void sslog(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"SOUNDSTREAM: %s", buf);

    static FILE *logFile = NULL;
    if (!logFile) {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *logPath = [[paths firstObject] stringByAppendingPathComponent:@"Logs/soundstream_debug.log"];
        logFile = fopen([logPath UTF8String], "a");
        if (!logFile) logFile = fopen("/tmp/soundstream_debug.log", "a");
    }
    if (logFile) { fprintf(logFile, "%s\n", buf); fflush(logFile); }
}

#pragma mark - Particle & Stream

typedef struct {
    float x, y;
    float vx, vy;
    float life, maxLife;
    float size;
    float opacity;
} Particle;

typedef struct {
    float x, y;
    float angle;
    float speed;
    float maxSpeed;
} StreamHead;

#pragma mark - HSL to RGB

static void hslToRGB(float h, float s, float l, float *r, float *g, float *b) {
    if (s == 0) { *r = *g = *b = l; return; }
    float q = l < 0.5f ? l * (1+s) : l + s - l*s;
    float p = 2*l - q;
    float hk = fmodf(h, 1.0f); if (hk < 0) hk += 1;
    float tc[3] = { hk+1.0f/3, hk, hk-1.0f/3 };
    float rgb[3];
    for (int i = 0; i < 3; i++) {
        if (tc[i] < 0) tc[i] += 1; if (tc[i] > 1) tc[i] -= 1;
        if      (tc[i] < 1.0f/6) rgb[i] = p + (q-p)*6*tc[i];
        else if (tc[i] < 0.5f)   rgb[i] = q;
        else if (tc[i] < 2.0f/3) rgb[i] = p + (q-p)*(2.0f/3 - tc[i])*6;
        else                      rgb[i] = p;
    }
    *r = rgb[0]; *g = rgb[1]; *b = rgb[2];
}

static float randf(void) { return (float)arc4random_uniform(10000) / 10000.0f; }

#pragma mark - ScreenSaverView

@interface soundstreamView () {
    NSOpenGLView *_glView;

    Particle   _particles[TOTAL_PARTICLES];
    StreamHead _heads[MAX_STREAMS];

    float _time;
    float _hue;
    float _aspect;

    BOOL _glReady;
}
@end

@implementation soundstreamView

- (instancetype)initWithFrame:(NSRect)frame isPreview:(BOOL)isPreview {
    self = [super initWithFrame:frame isPreview:isPreview];
    if (self) {
        sslog("=== initWithFrame called, isPreview=%d, frame=%.0fx%.0f ===",
              isPreview, frame.size.width, frame.size.height);
        [self setAnimationTimeInterval:1.0 / 60.0];
        _time = 0;
        _hue = randf();
        _glReady = NO;
        _aspect = 16.0f / 9.0f;

        for (int s = 0; s < MAX_STREAMS; s++) {
            _heads[s].x = 0;
            _heads[s].y = 0;
            _heads[s].angle = randf() * M_PI * 2.0f;
            _heads[s].speed = 1.5f;
            _heads[s].maxSpeed = 2.0f;
        }

        for (int i = 0; i < TOTAL_PARTICLES; i++) {
            _particles[i].life = 0;
        }
    }
    return self;
}

- (void)setupGLIfNeeded {
    if (_glReady) return;
    _glReady = YES;

    for (NSView *sub in [self.subviews copy])
        [sub removeFromSuperview];

    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFAMultisample,
        NSOpenGLPFASampleBuffers, 1,
        NSOpenGLPFASamples, 4,
        0
    };
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf) {
        NSOpenGLPixelFormatAttribute fallback[] = {
            NSOpenGLPFADoubleBuffer,
            NSOpenGLPFAColorSize, 24,
            0
        };
        pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:fallback];
    }
    if (!pf) { _glReady = NO; return; }

    _glView = [[NSOpenGLView alloc] initWithFrame:self.bounds pixelFormat:pf];
    if (!_glView) { _glReady = NO; return; }
    _glView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    GLint swapInt = 1;
    [_glView.openGLContext setValues:&swapInt forParameter:NSOpenGLContextParameterSwapInterval];
    [self addSubview:_glView];

    [_glView.openGLContext makeCurrentContext];
    glEnable(GL_BLEND);
    glEnable(GL_POINT_SMOOTH);
    glHint(GL_POINT_SMOOTH_HINT, GL_NICEST);
    glClearColor(0, 0, 0, 1);
}

- (void)startAnimation {
    [super startAnimation];
    [self setupGLIfNeeded];
    sslog("startAnimation called");
}

- (void)stopAnimation {
    [super stopAnimation];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [_glView setFrame:self.bounds];
}

- (void)drawRect:(NSRect)rect {
    [[NSColor blackColor] setFill];
    NSRectFill(rect);
}

#pragma mark - Stream head movement

- (void)updateHead:(StreamHead *)h dt:(float)dt {
    float edgeX = _aspect * 0.90f;
    float edgeY = 0.90f;

    // Distance to the nearest edge along current direction
    float cx = cosf(h->angle);
    float cy = sinf(h->angle);

    // Distance to each wall along movement direction
    float distToEdge = 999.0f;
    if (cx > 0.001f)  distToEdge = fminf(distToEdge, (edgeX - h->x) / cx);
    if (cx < -0.001f) distToEdge = fminf(distToEdge, (-edgeX - h->x) / cx);
    if (cy > 0.001f)  distToEdge = fminf(distToEdge, (edgeY - h->y) / cy);
    if (cy < -0.001f) distToEdge = fminf(distToEdge, (-edgeY - h->y) / cy);
    if (distToEdge < 0) distToEdge = 0;

    // Time to reach edge at current speed
    float timeToEdge = (h->speed > 0.01f) ? (distToEdge / h->speed) : 999.0f;

    // Brake zone: start braking when <0.4s from edge
    float brakeTime = 0.4f;

    if (timeToEdge < brakeTime) {
        // Rapid deceleration: speed proportional to remaining time squared
        float ratio = timeToEdge / brakeTime;
        float target = h->maxSpeed * ratio * ratio;
        h->speed += (target - h->speed) * 20.0f * dt;
        if (h->speed < 0.02f) h->speed = 0.02f;

        // When nearly stopped at edge: instant turn
        if (h->speed < 0.05f || distToEdge < 0.03f) {
            h->speed = 0;

            // Pick new angle pointing inward with randomness
            float toCenterAngle = atan2f(-h->y, -h->x);
            float spread = M_PI * 0.4f;
            h->angle = toCenterAngle + (randf() - 0.5f) * spread;

            // Immediate kick
            h->speed = h->maxSpeed * 0.15f;
        }
    } else {
        // Accelerate hard
        h->speed += (h->maxSpeed - h->speed) * 5.0f * dt;
    }

    h->x += cosf(h->angle) * h->speed * dt;
    h->y += sinf(h->angle) * h->speed * dt;

    // Safety clamp
    float cx2 = _aspect * 0.95f;
    float cy2 = 0.95f;
    if (fabsf(h->x) > cx2 || fabsf(h->y) > cy2) {
        h->x = fmaxf(-cx2, fminf(cx2, h->x));
        h->y = fmaxf(-cy2, fminf(cy2, h->y));
        float toCenterAngle = atan2f(-h->y, -h->x);
        h->angle = toCenterAngle + (randf() - 0.5f) * (M_PI * 0.3f);
        h->speed = h->maxSpeed * 0.2f;
    }
}

#pragma mark - Animate

- (void)animateOneFrame {
    if (!_glReady || !_glView.openGLContext) return;

    [_glView.openGLContext makeCurrentContext];
    CGLLockContext(_glView.openGLContext.CGLContextObj);

    float dt = 1.0f / 60.0f;
    _time += dt;
    _hue = fmodf(_time * 0.04f, 1.0f);

    NSSize size = _glView.bounds.size;
    if (size.width < 1 || size.height < 1) {
        CGLUnlockContext(_glView.openGLContext.CGLContextObj);
        return;
    }
    _aspect = size.width / size.height;
    float scaleFactor = _glView.window ? _glView.window.backingScaleFactor : 1.0f;

    for (int s = 0; s < MAX_STREAMS; s++) {
        _heads[s].maxSpeed = 2.0f;
        [self updateHead:&_heads[s] dt:dt];
    }

    // Emit trail particles for each stream
    for (int s = 0; s < MAX_STREAMS; s++) {
        StreamHead *h = &_heads[s];
        float speedRatio = fminf(h->speed / fmaxf(h->maxSpeed, 0.1f), 1.0f);
        int emitCount = (int)(8 + speedRatio * 28);

        float tailAngle = h->angle + M_PI;
        int base = s * PARTICLES_PER_STREAM;
        int emitted = 0;

        for (int j = 0; j < PARTICLES_PER_STREAM && emitted < emitCount; j++) {
            Particle *p = &_particles[base + j];
            if (p->life > 0) continue;

            float spread = 0.04f + (1.0f - speedRatio) * 0.06f;
            p->x = h->x + (randf() - 0.5f) * spread;
            p->y = h->y + (randf() - 0.5f) * spread;

            float fan = (randf() - 0.5f) * 0.7f;
            float driftAngle = tailAngle + fan;
            float driftSpeed = h->speed * (0.02f + randf() * 0.06f) + randf() * 0.01f;
            p->vx = cosf(driftAngle) * driftSpeed;
            p->vy = sinf(driftAngle) * driftSpeed;

            p->maxLife = 1.5f + randf() * 2.5f;
            p->life = p->maxLife;
            p->size = 3.0f + randf() * 5.0f + speedRatio * 5.0f;
            p->opacity = 0.4f + speedRatio * 0.4f;
            emitted++;
        }

    }

    // Update all particles
    for (int i = 0; i < TOTAL_PARTICLES; i++) {
        Particle *p = &_particles[i];
        if (p->life <= 0) continue;

        p->vx *= 0.997f;
        p->vy *= 0.997f;
        p->x += p->vx * dt;
        p->y += p->vy * dt;
        p->life -= dt;
    }

    // === Draw ===
    glViewport(0, 0, (GLsizei)(size.width * scaleFactor),
                     (GLsizei)(size.height * scaleFactor));
    glClear(GL_COLOR_BUFFER_BIT);

    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(-_aspect, _aspect, -1, 1, -1, 1);

    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    glBlendFunc(GL_SRC_ALPHA, GL_ONE);

    for (int s = 0; s < MAX_STREAMS; s++) {
        float streamHue = fmodf(_hue + (float)s / MAX_STREAMS, 1.0f);
        int base = s * PARTICLES_PER_STREAM;

        for (int j = 0; j < PARTICLES_PER_STREAM; j++) {
            Particle *p = &_particles[base + j];
            if (p->life <= 0) continue;

            float fadeIn = fminf((p->maxLife - p->life) * 8.0f, 1.0f);
            float fadeOut = fminf(p->life * 3.0f, 1.0f);
            float fade = p->opacity * fadeIn * fadeOut;

            float sz = p->size * scaleFactor;

            float r, g, b;

            // Glow
            glPointSize(fmaxf(sz * 3.0f, 1.0f));
            glBegin(GL_POINTS);
            hslToRGB(streamHue, 0.7f, 0.4f, &r, &g, &b);
            glColor4f(r, g, b, fade * 0.12f);
            glVertex2f(p->x, p->y);
            glEnd();

            // Core
            glPointSize(fmaxf(sz * 1.2f, 1.0f));
            glBegin(GL_POINTS);
            hslToRGB(streamHue, 0.5f, 0.65f, &r, &g, &b);
            glColor4f(r, g, b, fade * 0.5f);
            glVertex2f(p->x, p->y);
            glEnd();

            // Bright center
            glPointSize(fmaxf(sz * 0.35f, 1.0f));
            glBegin(GL_POINTS);
            glColor4f(1, 1, 1, fade * 0.35f);
            glVertex2f(p->x, p->y);
            glEnd();
        }
    }

    [_glView.openGLContext flushBuffer];
    CGLUnlockContext(_glView.openGLContext.CGLContextObj);
}

- (BOOL)hasConfigureSheet { return NO; }
- (NSWindow *)configureSheet { return nil; }

@end
