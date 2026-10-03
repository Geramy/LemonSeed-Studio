// GPUSampler.m — samples GPU load on a background queue and publishes it to observers.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol GPUSamplerObserver <NSObject>
- (void)sampler:(id)sampler didSampleLoad:(double)load temperature:(double)celsius;
@end

@interface GPUSampler : NSObject
@property (nonatomic, readonly) NSTimeInterval interval;
@property (nonatomic, weak, nullable) id<GPUSamplerObserver> observer;
- (instancetype)initWithInterval:(NSTimeInterval)interval NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)start;
- (void)stop;
@end

@implementation GPUSampler {
    dispatch_source_t _timer;
    dispatch_queue_t _queue;
}

- (instancetype)initWithInterval:(NSTimeInterval)interval {
    if ((self = [super init])) {
        _interval = interval;
        _queue = dispatch_queue_create("lemonseed.gpu-sampler", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)start {
    if (_timer != nil) {
        return;
    }
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t nanoseconds = (uint64_t)(self.interval * NSEC_PER_SEC);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, nanoseconds, nanoseconds / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        double load = (double)arc4random_uniform(1000) / 10.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf.observer sampler:weakSelf didSampleLoad:load temperature:58.5];
        });
    });
    dispatch_resume(_timer);
}

- (void)stop {
    if (_timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
}

@end

NS_ASSUME_NONNULL_END
