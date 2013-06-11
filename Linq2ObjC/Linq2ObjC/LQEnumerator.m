#import "LQEnumerator.h"
#import "Macros.h"

@implementation LQEnumerator

- (id)initWithFunction:(NSEnumerator*)src nextObjectBlock:(id(^)(NSEnumerator*))nextObject {
    if (self = [super init]) {
        _src = src;
        _nextObject = LQ_AUTORELEASE(Block_copy(nextObject));
    }
    
    return self;
}

- (id)nextObject {
    return _nextObject(_src);
}

+ (LQEnumerator*)enumeratorWithFunction:(NSEnumerator*)src nextObjectBlock:(id(^)(NSEnumerator*))nextObject {
    return [[self alloc] initWithFunction:src nextObjectBlock:nextObject];
}
@end

@interface LQEnumerableEnumerator : NSEnumerator {
    id(^nextObject_)();
}

- (id) initWithEnumerable:(id<LQEnumerable>)collection;
+ (LQEnumerableEnumerator*) enumeratorWithEnumerable:(id<LQEnumerable>)collection;

@property (nonatomic, retain) id<LQEnumerable> collection;
@end

@implementation LQEnumerableEnumerator

- (id) initWithEnumerable:(id<LQEnumerable>)collection {
    self = [super init];
    if (self) {
        // declare all the local state needed
        __block NSFastEnumerationState state = { 0 };
        __block id stackbuf[16];
        __block BOOL firstLoop = YES;
        __block long mutationsPtrValue;
        __block id* stackbufPtr = stackbuf;
        __block NSUInteger index = -1;
        __block NSUInteger lastCount = -1;
        
        id(^block)() = ^{
            if (index != -1 && lastCount != -1 && index < lastCount) {
                id obj = state.itemsPtr[index];
                index++;
                
                return obj;
            }
            
            NSUInteger count = [collection countByEnumeratingWithState:&state objects:stackbufPtr count: 16];
            if (!count) {
                return (id)nil;
            }
            
            lastCount = count;
            index = 0;
            
            id obj = state.itemsPtr[index];
            index++;
            
            return obj;
        };
        
        nextObject_ = Block_copy(block);
    }
    
    return self;
}

+ (LQEnumerableEnumerator*) enumeratorWithEnumerable:(id<LQEnumerable>)collection {
    return [[self alloc] initWithEnumerable:collection];
}

- (id) nextObject {
    return nextObject_();
}


- (void) dealloc {
    Block_release(nextObject_);
    [super dealloc];
}

@end


@implementation NSEnumerator(Linq)

@dynamic select;
- (LQSelectBlock) select {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQSelectBlock block = ^id<LQEnumerable>(LQProjection fn) {
        LQProjection sel = LQ_AUTORELEASE(Block_copy(fn));
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            id item = nil;
            while((item = [src nextObject])) {
                return sel(item);
            }
            
            return nil;
        }];
    };
    
    return LQ_AUTORELEASE(Block_copy(block));
}

@dynamic where;
- (LQWhereBlock) where {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQWhereBlock block = ^id<LQEnumerable>(LQPredicate fn) {
        LQPredicate filter = LQ_AUTORELEASE(Block_copy(fn));
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            id item = nil;
            while((item = [src nextObject])) {
                if (filter(item)) {
                    return item;
                }
            }
            
            return nil;
        }];
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic selectMany;
// Functional "bind", let's assume there is "yield" operator in ObjC, the
// result of calling a.SelectMany(LQSelectMany collectionSelector);
// where a is LQEnumerable would be:
// for(id item in a) {
//      for (id subitem in collectionSelector(item)) {
//          yield return subitem;
//      }
// }
- (LQSelectManyBlock) selectMany {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQSelectManyBlock block = ^id<LQEnumerable>(LQSelectMany fn) {
        LQSelectMany collectionSelector = LQ_AUTORELEASE(Block_copy(fn));
        __block NSEnumerator* it = nil;
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            while (true) {
                if (!it) {
                    id item = [src nextObject];
                    if (!item) {
                        return nil;
                    }
                    
                    id<LQEnumerable> collection = collectionSelector(item);
                    if (![collection respondsToSelector:@selector(objectEnumerator)]) {
                        it = [LQEnumerableEnumerator enumeratorWithEnumerable:collection];
                    } else {
                        it = [collection objectEnumerator];
                    }
                }
                
                id next = [it nextObject];
                if (next) {
                    return next;
                }
                
                it = nil;
            }
            
            return nil;
        }];
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic disctinct;
- (LQDistinctBlock) disctinct {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQDistinctBlock block = ^{
        __block NSMutableSet* returnedItems = [NSMutableSet set];
        
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            id item = nil;
            while((item = [src nextObject])) {
                if (![returnedItems containsObject:item]) {
                    [returnedItems addObject:item];
                    return item;
                }
            }
            
            return nil;
        }];
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic skip;
- (LQSkipBlock) skip {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQSkipBlock block = ^(NSUInteger count){
        __block NSUInteger i = 0;
        
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            while (i++ < count) {
                id item = [src nextObject];
                if (!item) {
                    return nil;
                }
            }
            
            return [src nextObject];
        }];
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic skipWhile;
- (LQSkipWithPredicateBlock) skipWhile {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQSkipWithPredicateBlock block = ^(LQPredicate fn){
        LQPredicate predicate = LQ_AUTORELEASE(Block_copy(fn));
        __block BOOL skip = YES;
        
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            id item = nil;
            while ((item = [src nextObject])) {
                if (skip && !predicate(item)) {
                    skip = NO;
                }
                
                if (!skip) {
                    return item;
                }
            }
            
            return nil;
        }];
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic take;
- (LQSTakeBlock) take {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQSTakeBlock block = ^(NSUInteger count){
        __block NSUInteger i = 0;
        
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            while (i++ < count) {
                return [src nextObject];
            }
            
            return nil;
        }];
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic takeWhile;
- (LQSTakeWithPredicateBlock) takeWhile {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQSTakeWithPredicateBlock block = ^(LQPredicate fn){
        LQPredicate predicate = LQ_AUTORELEASE(Block_copy(fn));
        
        return [LQEnumerator enumeratorWithFunction:weakSelf nextObjectBlock:^id(NSEnumerator* src) {
            id item = nil;
            while ((item = [src nextObject])) {
                if (!predicate(item)) {
                    return nil;
                }
                
                return item;
            }
            
            return nil;
        }];
    };
    
    return [Block_copy(block) autorelease];

}

@dynamic all;
- (LQAllBlock) all {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQAllBlock block = ^(LQPredicate fn){
        LQPredicate predicate = LQ_AUTORELEASE(Block_copy(fn));
        
        for (id item in weakSelf) {
            if (!predicate(item)) {
                return NO;
            }
        }
        
        return YES;
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic any;
- (LQAnyBlock) any {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQAllBlock block = ^(LQPredicate fn){
        LQPredicate predicate = LQ_AUTORELEASE(Block_copy(fn));
        
        for (id item in weakSelf) {
            if (predicate(item)) {
                return YES;
            }
        }
        
        return NO;
    };
    
    return [Block_copy(block) autorelease];

}

@dynamic aggregateWithSeed;
- (LQAggregateWithSeed) aggregateWithSeed {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQAggregateWithSeed block = ^(id seed, LQAggregator aggregator) {
        for (id item in weakSelf) {
            seed = aggregator(seed, item);
        }
        
        return seed;
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic aggregate;
- (LQAggregate) aggregate {
    WeakRefAttribute NSEnumerator* weakSelf = self;
    LQAggregate block = ^(LQAggregator fn) {
        return weakSelf.aggregateWithSeed(nil, fn);
    };
    
    return [Block_copy(block) autorelease];
}

@dynamic toArray;
- (NSArray*) toArray {
    return [self allObjects];
}

@end