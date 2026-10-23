#import "UCDisasmViewController.h"
#import "UCPseudocodeViewController.h"
#import "UCAnalysisCenterViewController.h"
#import "UCClassBrowserViewController.h"
#import "UCXrefListViewController.h"
#import "AVX512Color.h"
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

#pragma mark - UCDisasmViewController

@interface UCDisasmViewController () <UIScrollViewDelegate>

@property (nonatomic, strong) UIView *loadingOverlay;
@property (nonatomic, strong) UIImageView *loadingLogo;
@property (nonatomic, strong) UIProgressView *loadingProgressView;
@property (nonatomic, strong) UILabel *loadingStatusLabel;
@property (nonatomic, strong) UILabel *statusLabel;

@property (nonatomic, strong) UCDisasmResult *disasmResult;

@property (nonatomic, assign) uint64_t startAddress;
@property (nonatomic, assign) NSUInteger codeSize;
@property (nonatomic, copy) NSString *navTitle;

@property (nonatomic, strong) UILabel *modeLabel;
@property (nonatomic, strong) UIScrollView *graphScrollView;
@property (nonatomic, strong) UCCFGView *cfgView;
@property (nonatomic, strong) UIView *graphStatusBar;
@property (nonatomic, strong) UILabel *graphStatusLabel;
@property (nonatomic, strong) UIButton *zoomInBtn;
@property (nonatomic, strong) UIButton *zoomOutBtn;
@property (nonatomic, strong) UIButton *zoomResetBtn;

@property (nonatomic, strong) UCFunction *currentFunction;

@end

@implementation UCDisasmViewController

#pragma mark - Initial initialisation to start-in

- (instancetype)initWithAddress:(uint64_t)address size:(NSUInteger)size title:(NSString *)title {
    self = [super init];
    if (self) {
        _startAddress = address;
        _codeSize = size;
        _navTitle = title ?: [NSString stringWithFormat:@"0x%llx", address];
        _viewMode = UCDisasmViewModeGraph;
    }
    return self;
}

- (instancetype)initWithMethod:(Method)method class:(NSString *)className selector:(NSString *)selectorName {
    if (!method) return nil;
    
    IMP imp = method_getImplementation(method);
    NSString *title = [NSString stringWithFormat:@"%@ %@",
                       className ?: @"Unknown",
                       selectorName ?: @"unknown"];
    
    // 4096 is only a bounded decode window; actual function size comes from analysis.
    return [self initWithAddress:(uint64_t)imp size:(64 * 1024) title:title];
}

- (instancetype)initWithClass:(Class)cls selector:(SEL)selector isClassMethod:(BOOL)isClassMethod {
    if (!cls || !selector) return nil;
    
    Method method = NULL;
    if (isClassMethod) {
        method = class_getClassMethod(cls, selector);
    } else {
        method = class_getInstanceMethod(cls, selector);
    }
    
    NSString *className = NSStringFromClass(cls);
    NSString *selName = NSStringFromSelector(selector);
    NSString *title = [NSString stringWithFormat:@"%@[%@ %@]",
                       isClassMethod ? @"+" : @"-",
                       className, selName];
    
    return [self initWithMethod:method class:className selector:selName];
}

- (instancetype)initWithFunction:(UCFunction *)function title:(NSString *)title {
    self = [super init];
    if (self) {
        _currentFunction = function;
        _startAddress = function.startAddress;
        _codeSize = function.size;
        _navTitle = title ?: function.name;
        _viewMode = UCDisasmViewModeGraph;
    }
    return self;
}

#pragma mark - The life cycle of the

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AVX512Color.primaryBackgroundColor;
    self.title = self.navTitle;
    
    [self setupNavigationBar];
    [self setupViewModeControl];
    [self setupGraphView];
    [self setupLoadingIndicator];

    [self loadDisassembly];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGFloat top = self.view.safeAreaInsets.top;
    CGFloat bottom = self.view.safeAreaInsets.bottom;
    CGFloat width = self.view.bounds.size.width;

    CGFloat labelH = 32;
    self.modeLabel.frame = CGRectMake(10, top + 5, width - 20, labelH);

    CGFloat graphY = top + labelH + 10;
    CGFloat statusBarH = 32;
    CGFloat graphH = self.view.bounds.size.height - graphY - bottom;

    self.graphStatusBar.hidden = NO;
    self.graphStatusBar.frame = CGRectMake(0, self.view.bounds.size.height - bottom - statusBarH, width, statusBarH);
    self.graphScrollView.frame = CGRectMake(0, graphY, width, graphH - statusBarH);

    CGFloat btnW = 44;
    CGFloat btnH = statusBarH;
    CGFloat resetW = 52;
    self.zoomInBtn.frame = CGRectMake(width - btnW, 0, btnW, btnH);
    self.zoomResetBtn.frame = CGRectMake(width - btnW - 4 - resetW, 0, resetW, btnH);
    self.zoomOutBtn.frame = CGRectMake(width - btnW - 4 - resetW - 4 - btnW, 0, btnW, btnH);
    self.graphStatusLabel.frame = CGRectMake(12, 0, width - btnW * 2 - resetW - 24, btnH);

    CGFloat overlayW = MIN(220, width - 40);
    self.loadingOverlay.bounds = CGRectMake(0, 0, overlayW, 150);
    self.loadingOverlay.center = CGPointMake(width / 2, graphY + graphH / 2);
    self.loadingLogo.frame = CGRectMake((overlayW - 64) / 2, 0, 64, 64);
    self.loadingProgressView.frame = CGRectMake(0, 86, overlayW, 2);
    self.loadingStatusLabel.frame = CGRectMake(0, 98, overlayW, 32);
}

- (void)setupNavigationBar {
    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];
    
    UIBarButtonItem *more = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self
        action:@selector(moreAction)];
    
    self.navigationItem.rightBarButtonItems = @[done, more];
}

- (void)setupViewModeControl {
    self.modeLabel = [[UILabel alloc] init];
    // Was a garbled, never-finished placeholder string ("CFGGUI graphics to
    // the") that shipped straight to the top bar.
    self.modeLabel.text = @"Control Flow Graph";
    self.modeLabel.textAlignment = NSTextAlignmentCenter;
    self.modeLabel.font = [UIFont boldSystemFontOfSize:13];
    self.modeLabel.textColor = AVX512Color.appAccentColor;
    [self.view addSubview:self.modeLabel];
}

- (void)setupGraphView {
    self.graphScrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
    // Was a light-blue/white canvas — flipped to black, with the graph's own
    // gradient (below) carrying a subtle tint of the app's real accent color
    // instead of a hardcoded generic blue, so this still feels like the rest
    // of the app rather than a bolted-on light-mode tool.
    self.graphScrollView.backgroundColor = [UIColor colorWithWhite:0.04 alpha:1.0];
    self.graphScrollView.minimumZoomScale = 0.3;
    self.graphScrollView.maximumZoomScale = 3.0;
    self.graphScrollView.delegate = self;
    self.graphScrollView.hidden = NO;
    [self.view addSubview:self.graphScrollView];
    
    self.cfgView = [[UCCFGView alloc] initWithFrame:CGRectZero];
    __weak typeof(self) weakSelf = self;
    self.cfgView.blockTapHandler = ^(UCBasicBlock *block) {
        [weakSelf handleBasicBlockTap:block];
    };
    self.cfgView.blockLongPressHandler = ^(UCBasicBlock *block) {
        [weakSelf handleBasicBlockLongPress:block];
    };
    self.cfgView.instructionTapHandler = ^(UCDisasmInstruction *instruction) {
        [weakSelf handleInstructionTap:instruction];
    };
    [self.graphScrollView addSubview:self.cfgView];
    
    [self setupGraphStatusBar];
}

- (void)setupGraphStatusBar {
    self.graphStatusBar = [[UIView alloc] init];
    self.graphStatusBar.backgroundColor = [UIColor colorWithRed:0.25 green:0.30 blue:0.40 alpha:0.95];
    self.graphStatusBar.layer.borderWidth = 0.5;
    self.graphStatusBar.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:1.0].CGColor;
    [self.view addSubview:self.graphStatusBar];
    
    self.graphStatusLabel = [[UILabel alloc] init];
    self.graphStatusLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:11];
    self.graphStatusLabel.textColor = [UIColor whiteColor];
    // Was another unfinished placeholder string ("CFG: How you are in the
    // process of...") — replaced on load by updateCFGView's real summary
    // (block/byte/instruction counts), this is just what's briefly visible
    // before that.
    self.graphStatusLabel.text = @"Loading control flow graph…";
    [self.graphStatusBar addSubview:self.graphStatusLabel];
    
    self.zoomOutBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    // Was garbled placeholder text ("---... uh") that showed up literally in
    // the toolbar instead of a minus sign.
    [self.zoomOutBtn setTitle:@"−" forState:UIControlStateNormal];
    [self.zoomOutBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.zoomOutBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.zoomOutBtn addTarget:self action:@selector(zoomOutAction) forControlEvents:UIControlEventTouchUpInside];
    [self.graphStatusBar addSubview:self.zoomOutBtn];
    
    self.zoomResetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.zoomResetBtn setTitle:@"100%" forState:UIControlStateNormal];
    [self.zoomResetBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.zoomResetBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [self.zoomResetBtn addTarget:self action:@selector(zoomResetAction) forControlEvents:UIControlEventTouchUpInside];
    [self.graphStatusBar addSubview:self.zoomResetBtn];
    
    self.zoomInBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    // Was garbled placeholder text ("+ ⁇  plus-") that showed up literally in
    // the toolbar instead of a plus sign.
    [self.zoomInBtn setTitle:@"+" forState:UIControlStateNormal];
    [self.zoomInBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.zoomInBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [self.zoomInBtn addTarget:self action:@selector(zoomInAction) forControlEvents:UIControlEventTouchUpInside];
    [self.graphStatusBar addSubview:self.zoomInBtn];
}

- (void)zoomInAction {
    CGFloat newScale = self.graphScrollView.zoomScale * 1.2;
    if (newScale > self.graphScrollView.maximumZoomScale) {
        newScale = self.graphScrollView.maximumZoomScale;
    }
    [self.graphScrollView setZoomScale:newScale animated:YES];
    [self updateZoomLabel];
}

- (void)zoomOutAction {
    CGFloat newScale = self.graphScrollView.zoomScale / 1.2;
    if (newScale < self.graphScrollView.minimumZoomScale) {
        newScale = self.graphScrollView.minimumZoomScale;
    }
    [self.graphScrollView setZoomScale:newScale animated:YES];
    [self updateZoomLabel];
}

- (void)zoomResetAction {
    [self.graphScrollView setZoomScale:1.0 animated:YES];
    [self updateZoomLabel];
}

- (void)updateZoomLabel {
    NSInteger percent = (NSInteger)(self.graphScrollView.zoomScale * 100);
    [self.zoomResetBtn setTitle:[NSString stringWithFormat:@"%ld%%", (long)percent] forState:UIControlStateNormal];
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
    if (scrollView == self.graphScrollView) {
        [self updateZoomLabel];
    }
}

- (void)setupLoadingIndicator {
    // Was a plain spinner with no real progress signal — if the view ever
    // sat on one frame for a while (eg. building a lot of block views on a
    // large function) it was indistinguishable from actually being hung.
    // This is a real progress bar driven by actual load/layout stages, with
    // the app's own mark on it instead of a generic system spinner.
    self.loadingOverlay = [[UIView alloc] init];
    self.loadingOverlay.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.loadingOverlay];

    self.loadingLogo = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"airshare_mark"]];
    self.loadingLogo.contentMode = UIViewContentModeScaleAspectFit;
    [self.loadingOverlay addSubview:self.loadingLogo];

    self.loadingProgressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.loadingProgressView.progressTintColor = AVX512Color.appAccentColor;
    self.loadingProgressView.trackTintColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    self.loadingProgressView.progress = 0.0;
    self.loadingProgressView.layer.cornerRadius = 1;
    self.loadingProgressView.clipsToBounds = YES;
    [self.loadingOverlay addSubview:self.loadingProgressView];

    self.loadingStatusLabel = [[UILabel alloc] init];
    self.loadingStatusLabel.font = [UIFont systemFontOfSize:12];
    self.loadingStatusLabel.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    self.loadingStatusLabel.textAlignment = NSTextAlignmentCenter;
    self.loadingStatusLabel.numberOfLines = 2;
    self.loadingStatusLabel.text = @"Disassembling…";
    [self.loadingOverlay addSubview:self.loadingStatusLabel];
}

/// Updates the loading overlay's progress bar + status text. `progress` is
/// 0...1; pass a value >= 1.0 to let `hideLoadingOverlay` fade it out.
- (void)setLoadingProgress:(float)progress status:(NSString *)status {
    self.loadingOverlay.hidden = NO;
    self.loadingOverlay.alpha = 1.0;
    [self.loadingProgressView setProgress:MAX(0.02, progress) animated:YES];
    if (status.length > 0) self.loadingStatusLabel.text = status;
}

- (void)hideLoadingOverlay {
    [UIView animateWithDuration:0.2 animations:^{
        self.loadingOverlay.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.loadingOverlay.hidden = YES;
    }];
}

#pragma mark - In addition to the compilation in re-

- (void)loadDisassembly {
    [self setLoadingProgress:0.08 status:@"Disassembling…"];
    // Block views get built and placed incrementally — before layoutGraph
    // positions everything, their frames all still default to (0,0,w,h), so
    // they stack directly on top of each other. With the graph canvas
    // visible underneath the (small, non-opaque) loading overlay, that
    // half-built stack showed through as a garbled mess of overlapping
    // cards. Hide the whole canvas until it's actually ready, and only
    // reveal it once it's positioned — see finishCFGLayout.
    self.graphScrollView.hidden = YES;

    __weak typeof(self) weakSelf = self;
    uint64_t startAddr = self.startAddress;
    NSUInteger codeSz = self.codeSize;
    UCFunction *existingFunc = self.currentFunction;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        UCDisassembler *disasm = [UCDisassembler sharedInstance];
        UCDisasmResult *result = nil;
        UCFunction *function = nil;
        
        if (existingFunc) {
            function = existingFunc;
            result = [disasm disassembleAtAddress:function.startAddress
                                             size:function.size];
        } else {
            function = [disasm analyzeFunctionAtAddress:startAddr
                                               maxSize:codeSz];
            if (function) {
                result = [disasm disassembleAtAddress:function.startAddress
                                                 size:function.size];
                if (result) {
                    result.functions = @[function];
                }
            } else {
                result = [disasm disassembleAtAddress:startAddr
                                                 size:codeSz];
                // analyzeFunctionAtAddress: found no clean function boundary here —
                // a common case for a jump target that's a stub/thunk/imported-symbol
                // trampoline rather than a real LC_FUNCTION_STARTS entry. Rather than
                // leaving the viewer blank, still build a real CFG over whatever we
                // *could* decode: every instruction below is still a real, decoded
                // instruction, only the "this is exactly one whole function" boundary
                // claim is relaxed to "this is the decoded window from here".
                if (result && result.instructions.count > 0) {
                    NSArray<UCBasicBlock *> *blocks = [disasm buildCFG:result.instructions];
                    if (blocks.count > 0) {
                        UCFunction *synthesized = [[UCFunction alloc] init];
                        synthesized.startAddress = startAddr;
                        UCDisasmInstruction *lastInsn = result.instructions.lastObject;
                        synthesized.endAddress = lastInsn ? (lastInsn.address + lastInsn.size) : startAddr;
                        synthesized.size = (NSUInteger)(synthesized.endAddress - synthesized.startAddress);
                        synthesized.boundaryIsBounded = YES;
                        synthesized.name = self.navTitle ?: [NSString stringWithFormat:@"sub_%llx", startAddr];
                        synthesized.instructions = result.instructions;
                        synthesized.basicBlocks = blocks;
                        synthesized.basicBlockCount = blocks.count;
                        function = synthesized;
                        result.functions = @[function];
                    }
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.disasmResult = result;
            strongSelf.currentFunction = function;

            if (function) {
                [strongSelf setLoadingProgress:0.45 status:@"Building control flow graph…"];
                strongSelf.navTitle = function.name;
                strongSelf.title = function.name;
                [strongSelf updateCFGView];
            } else {
                // Genuinely undecodable (unmapped/unreadable region, or Capstone
                // produced nothing at all) — say so explicitly instead of leaving
                // an unexplained blank graph behind the placeholder status text.
                // The canvas was hidden going into this load, so it has to be
                // brought back for the status message to actually be visible.
                strongSelf.graphScrollView.hidden = NO;
                [strongSelf hideLoadingOverlay];
                strongSelf.graphStatusLabel.text = [NSString stringWithFormat:
                    @"Could not disassemble 0x%llx — not a decodable code region.", startAddr];
            }
        });
    });
}

- (void)updateCFGView {
    if (!self.currentFunction) return;

    NSArray<UCBasicBlock *> *blocks = self.currentFunction.basicBlocks;
    __weak typeof(self) weakSelf = self;

    // Building one view per basic block (each with its own attributed-string
    // instruction listing) synchronously on the main thread is what made a
    // large function's loading screen look permanently stuck: no runloop
    // turn ran until every block view existed, so nothing on screen — the
    // progress bar included — could move. This builds them a handful at a
    // time so the bar (and the rest of the UI) actually stays live.
    [self.cfgView buildBlockViewsAsync:blocks progress:^(float fraction) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setLoadingProgress:(0.45f + fraction * 0.45f)
                                 status:[NSString stringWithFormat:@"Laying out blocks… %d%%", (int)(fraction * 100)]];
    } completion:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf finishCFGLayout];
    }];
}

- (void)finishCFGLayout {
    [self setLoadingProgress:0.97 status:@"Finishing…"];
    [self.cfgView layoutGraph];

    self.graphScrollView.contentSize = self.cfgView.bounds.size;

    CGSize viewSize = self.graphScrollView.bounds.size;
    CGSize contentSize = self.cfgView.bounds.size;

    if (contentSize.width > 0 && contentSize.height > 0 && viewSize.width > 0 && viewSize.height > 0) {
        CGFloat scaleX = viewSize.width / contentSize.width;
        CGFloat scaleY = viewSize.height / contentSize.height;
        CGFloat fitScale = MIN(scaleX, scaleY) * 0.95;

        fitScale = MIN(fitScale, 1.0);
        fitScale = MAX(fitScale, self.graphScrollView.minimumZoomScale);

        self.graphScrollView.zoomScale = fitScale;

        CGPoint offset = CGPointMake(
            (contentSize.width * fitScale - viewSize.width) / 2,
            (contentSize.height * fitScale - viewSize.height) / 2
        );
        self.graphScrollView.contentOffset = offset;
    }

    NSString *funcName = self.currentFunction.name;
    if (funcName.length > 40) {
        funcName = [NSString stringWithFormat:@"%@...", [funcName substringToIndex:40]];
    }

    self.graphStatusLabel.text = [NSString stringWithFormat:@"%@  |  %lu blocks  |  %lu %@  |  %lu instr",
                                   funcName,
                                   (unsigned long)self.currentFunction.basicBlockCount,
                                   (unsigned long)self.currentFunction.size,
                                   self.currentFunction.boundaryIsBounded ? @"bytes (bounded)" : @"bytes",
                                   (unsigned long)self.currentFunction.instructions.count];

    [self updateZoomLabel];
    [self.view setNeedsLayout];
    // Reveal only now that every block view has its real, final position and
    // the scroll view is already zoomed/offset to fit — so what appears is
    // exactly the finished graph in one step, not the half-built stack from
    // partway through loading.
    self.graphScrollView.hidden = NO;
    [self hideLoadingOverlay];
}

- (void)handleInstructionTap:(UCDisasmInstruction *)insn {
    if (!insn) return;

    if (insn.xrefFrom.count > 0) {
        UCXrefListViewController *xrefVC = [[UCXrefListViewController alloc]
            initWithTargetAddress:insn.address
                       sourceAddresses:insn.xrefFrom];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:xrefVC];
        [self presentViewController:nav animated:YES completion:nil];
        return;
    }

    // No inbound xrefs to browse; if this instruction calls somewhere, offer
    // to jump forward to the callee instead of doing nothing on tap.
    if (insn.isCall && insn.branchTarget > 0) {
        NSString *label = insn.comment.length > 0
            ? insn.comment
            : [NSString stringWithFormat:@"0x%llx", insn.branchTarget];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:@"No inbound references"
                              message:[NSString stringWithFormat:@"Jump to call target %@?", label]
                       preferredStyle:UIAlertControllerStyleAlert];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Jump" style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            UCDisasmViewController *targetVC = [[UCDisasmViewController alloc]
                initWithAddress:insn.branchTarget size:(64 * 1024) title:label];
            [strongSelf.navigationController pushViewController:targetVC animated:YES];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

- (void)handleBasicBlockTap:(UCBasicBlock *)block {
    if (!block) return;

    NSMutableArray<NSNumber *> *touchedIds = [NSMutableArray array];

    UIView *blockView = self.cfgView.blockViewMap[@(block.blockId)];
    if (blockView) {
        blockView.backgroundColor = [UIColor colorWithRed:0.45 green:0.38 blue:0.08 alpha:1.0]; // selected: gold
        [touchedIds addObject:@(block.blockId)];
    }

    for (UCBasicBlock *pred in block.predecessors) {
        UIView *predView = self.cfgView.blockViewMap[@(pred.blockId)];
        if (predView) {
            predView.backgroundColor = [UIColor colorWithRed:0.10 green:0.22 blue:0.42 alpha:1.0]; // predecessors: blue
            [touchedIds addObject:@(pred.blockId)];
        }
    }

    // Distinguish the two branch directions out of a conditional instead of
    // tinting every successor the same green — matches the true/false edge
    // colors in drawEdges so tapping a block tells you which way is which
    // without having to trace the lines yourself.
    for (UCBasicBlock *succ in block.successors) {
        UIView *succView = self.cfgView.blockViewMap[@(succ.blockId)];
        if (!succView) continue;
        if (succ.type == UCBasicBlockTypeConditionalFalse) {
            succView.backgroundColor = [UIColor colorWithRed:0.38 green:0.10 blue:0.10 alpha:1.0]; // false: red
        } else {
            succView.backgroundColor = [UIColor colorWithRed:0.10 green:0.32 blue:0.12 alpha:1.0]; // true/default: green
        }
        [touchedIds addObject:@(succ.blockId)];
    }

    // Was reset to plain white — a leftover from when block cards had a
    // white background. The cards are dark now, so resetting to white left
    // every tapped block (and its neighbors) stuck bright white forever.
    UIColor *restingColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for (NSNumber *blockId in touchedIds) {
            UIView *currentView = self.cfgView.blockViewMap[blockId];
            if (currentView) {
                [UIView animateWithDuration:0.3 animations:^{
                    currentView.backgroundColor = restingColor;
                }];
            }
        }
    });

    [self centerOnBlock:block animated:YES];
}

/// Scrolls (and, if the graph is currently zoomed out past comfortable
/// reading size, zooms back in) so the given block is centered in the
/// visible viewport. Used both for a direct tap and for "jump to
/// predecessor/successor" from the long-press menu, so jumping to a block
/// that's off-screen actually brings it into view instead of just flashing
/// a highlight nobody can see.
- (void)centerOnBlock:(UCBasicBlock *)block animated:(BOOL)animated {
    UIView *blockView = self.cfgView.blockViewMap[@(block.blockId)];
    if (!blockView) return;

    CGFloat targetZoom = self.graphScrollView.zoomScale;
    if (targetZoom < 0.7) targetZoom = 0.9;
    targetZoom = MIN(MAX(targetZoom, self.graphScrollView.minimumZoomScale), self.graphScrollView.maximumZoomScale);

    void (^centerNow)(void) = ^{
        // blockView's frame is already in cfgView's own coordinate space
        // (cfgView is its direct superview), so this just needs scaling by
        // the current zoom to land in the scroll view's content coordinates.
        CGRect blockFrame = blockView.frame;
        CGPoint center = CGPointMake(
            CGRectGetMidX(blockFrame) * self.graphScrollView.zoomScale,
            CGRectGetMidY(blockFrame) * self.graphScrollView.zoomScale
        );
        CGSize viewportSize = self.graphScrollView.bounds.size;
        CGPoint offset = CGPointMake(center.x - viewportSize.width / 2, center.y - viewportSize.height / 2);

        CGSize contentSize = self.graphScrollView.contentSize;
        offset.x = MIN(MAX(offset.x, 0), MAX(0, contentSize.width - viewportSize.width));
        offset.y = MIN(MAX(offset.y, 0), MAX(0, contentSize.height - viewportSize.height));

        [self.graphScrollView setContentOffset:offset animated:animated];
    };

    if (fabs(targetZoom - self.graphScrollView.zoomScale) > 0.01) {
        [UIView animateWithDuration:animated ? 0.25 : 0 animations:^{
            self.graphScrollView.zoomScale = targetZoom;
        } completion:^(BOOL finished) {
            centerNow();
        }];
    } else {
        centerNow();
    }
}

/// Long-press menu for a block: jump straight to a specific predecessor or
/// successor (by name/address, not just a highlight flash), open the same
/// spot in the linear disassembly browser, or copy the address.
- (void)handleBasicBlockLongPress:(UCBasicBlock *)block {
    if (!block) return;

    NSString *addrTitle = [NSString stringWithFormat:@"loc_%llx", block.startAddress];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:addrTitle
                                                                     message:nil
                                                              preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;

    if (self.currentFunction) {
        [alert addAction:[UIAlertAction actionWithTitle:@"View in Linear Disassembly"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            UCDisassemblerBrowserViewController *vc = [[UCDisassemblerBrowserViewController alloc]
                initWithFunction:strongSelf.currentFunction
                            title:strongSelf.currentFunction.name
                 highlightAddress:block.startAddress];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            [strongSelf presentViewController:nav animated:YES completion:nil];
        }]];
    }

    for (UCBasicBlock *pred in block.predecessors) {
        NSString *label = [NSString stringWithFormat:@"Jump to predecessor loc_%llx", pred.startAddress];
        [alert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleBasicBlockTap:pred];
        }]];
    }

    for (UCBasicBlock *succ in block.successors) {
        NSString *branchLabel = @"successor";
        if (succ.type == UCBasicBlockTypeConditionalTrue) branchLabel = @"true branch";
        else if (succ.type == UCBasicBlockTypeConditionalFalse) branchLabel = @"false branch";
        NSString *label = [NSString stringWithFormat:@"Jump to %@ loc_%llx", branchLabel, succ.startAddress];
        [alert addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf handleBasicBlockTap:succ];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Block Address" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"0x%llx", block.startAddress];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        UIView *blockView = self.cfgView.blockViewMap[@(block.blockId)];
        alert.popoverPresentationController.sourceView = self.view;
        if (blockView) {
            alert.popoverPresentationController.sourceRect = [self.view convertRect:blockView.bounds fromView:blockView];
        }
    }

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UIScrollViewDelegate

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    if (scrollView == self.graphScrollView) {
        return self.cfgView;
    }
    return nil;
}

#pragma mark - Operation of the operation operations

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)moreAction {
    // Was another garbled placeholder string ("Options options to the
    // option") that shipped straight to the alert title.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"More Options"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;

    [alert addAction:[UIAlertAction actionWithTitle:@"Class Browser"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        UCClassBrowserViewController *classBrowserVC = [[UCClassBrowserViewController alloc] init];
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:classBrowserVC];
        [strongSelf presentViewController:nav animated:YES completion:nil];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - UCCFGView

#pragma mark - UCInstructionTextView

/// A UITextView that knows which instruction produced each rendered line,
/// so a tap can be mapped back to the originating UCDisasmInstruction.
/// Relies on createBlockView: emitting exactly one line per instruction.
@interface UCInstructionTextView : UITextView
@property (nonatomic, strong, nullable) NSArray<UCDisasmInstruction *> *lineInstructions;
@end

@implementation UCInstructionTextView
@end

@interface UCCFGView ()

@property (nonatomic, strong) NSMutableArray *blockViews;
@property (nonatomic, strong) NSMutableArray *edgeLayers;
@property (nonatomic, strong, readwrite) NSMutableDictionary *blockViewMap;
@property (nonatomic, strong) CAGradientLayer *bgGradient;
@property (nonatomic, strong, readwrite) NSSet<NSNumber *> *loopBlockIds;

@end

@implementation UCCFGView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.blockViews = [NSMutableArray array];
        self.edgeLayers = [NSMutableArray array];
        self.blockViewMap = [NSMutableDictionary dictionary];
        
        self.bgGradient = [CAGradientLayer layer];
        // Was a light-blue/white gradient — now black at the edges with a
        // dark, low-brightness tint of the app's real accent color toward
        // the center, so the CFG canvas itself carries the app's branding
        // instead of a generic light "diagram tool" look.
        UIColor *accent = AVX512Color.appAccentColor;
        CGFloat ar = 0, ag = 0, ab = 0, aa = 0;
        [accent getRed:&ar green:&ag blue:&ab alpha:&aa];
        UIColor *accentDark = [UIColor colorWithRed:ar * 0.22 green:ag * 0.22 blue:ab * 0.22 alpha:1.0];
        self.bgGradient.colors = @[
            (__bridge id)[UIColor colorWithWhite:0.03 alpha:1.0].CGColor,
            (__bridge id)accentDark.CGColor
        ];
        [self.layer addSublayer:self.bgGradient];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.bgGradient.frame = self.bounds;
}

- (void)setBasicBlocks:(NSArray<UCBasicBlock *> *)basicBlocks {
    _basicBlocks = basicBlocks;
    self.loopBlockIds = [self computeLoopBlockIds];

    for (UIView *v in self.blockViews) [v removeFromSuperview];
    for (CALayer *l in self.edgeLayers) [l removeFromSuperlayer];
    [self.blockViews removeAllObjects];
    [self.edgeLayers removeAllObjects];
    [self.blockViewMap removeAllObjects];
    
    if (!basicBlocks) return;
    
    for (UCBasicBlock *block in basicBlocks) {
        UIView *blockView = [self createBlockView:block];
        [self addSubview:blockView];
        [self.blockViews addObject:blockView];
        self.blockViewMap[@(block.blockId)] = blockView;
    }
}

- (void)buildBlockViewsAsync:(NSArray<UCBasicBlock *> *)basicBlocks
                     progress:(void (^)(float fraction))progress
                   completion:(void (^)(void))completion {
    _basicBlocks = basicBlocks;
    self.loopBlockIds = [self computeLoopBlockIds];

    for (UIView *v in self.blockViews) [v removeFromSuperview];
    for (CALayer *l in self.edgeLayers) [l removeFromSuperlayer];
    [self.blockViews removeAllObjects];
    [self.edgeLayers removeAllObjects];
    [self.blockViewMap removeAllObjects];

    if (basicBlocks.count == 0) {
        if (progress) progress(1.0);
        if (completion) completion();
        return;
    }

    NSUInteger total = basicBlocks.count;
    // Small enough per-tick to keep each runloop turn under a frame or two,
    // large enough that a huge function (thousands of blocks) still finishes
    // in a reasonable number of turns rather than one per block.
    const NSUInteger batchSize = 8;

    __weak typeof(self) weakSelf = self;
    __block NSUInteger nextIndex = 0;
    __block void (^buildBatch)(void) = nil;
    void (^buildBatchImpl)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSUInteger end = MIN(nextIndex + batchSize, total);
        for (NSUInteger i = nextIndex; i < end; i++) {
            UCBasicBlock *block = basicBlocks[i];
            UIView *blockView = [strongSelf createBlockView:block];
            [strongSelf addSubview:blockView];
            [strongSelf.blockViews addObject:blockView];
            strongSelf.blockViewMap[@(block.blockId)] = blockView;
        }
        nextIndex = end;

        if (progress) progress((float)nextIndex / (float)total);

        if (nextIndex < total) {
            dispatch_async(dispatch_get_main_queue(), buildBatch);
        } else {
            buildBatch = nil; // break the retain cycle now that we're done
            if (completion) completion();
        }
    };
    buildBatch = buildBatchImpl;
    buildBatch();
}

- (UIView *)createBlockView:(UCBasicBlock *)block {
    UIView *view = [[UIView alloc] init];
    // Was a plain white card — now a dark card so it matches the rest of the
    // app's black theme instead of looking like a bolted-on light-mode tool.
    // Every text color below that assumed a white background is flipped to
    // its light-on-dark counterpart in the same pass.
    view.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    view.layer.borderWidth = 1.0;
    view.layer.cornerRadius = 4;
    view.clipsToBounds = YES;
    view.layer.shadowColor = [UIColor blackColor].CGColor;
    view.layer.shadowOffset = CGSizeMake(0, 2);
    view.layer.shadowRadius = 3;
    view.layer.shadowOpacity = 0.35;
    view.layer.masksToBounds = NO;

    // Default/"normal" blocks (no entry/exit/conditional semantics of their
    // own) are tinted with the app's real accent color instead of a generic
    // blue-gray — entry/exit/conditional blocks keep their meaningful
    // green/red coding untouched.
    UIColor *borderColor = AVX512Color.appAccentColor;
    UIColor *headerColor = [UIColor colorWithRed:0.70 green:0.80 blue:0.92 alpha:1.0];
    
    switch (block.type) {
        case UCBasicBlockTypeEntry:
            borderColor = [UIColor colorWithRed:0.20 green:0.70 blue:0.20 alpha:1.0];
            headerColor = [UIColor colorWithRed:0.65 green:0.88 blue:0.65 alpha:1.0];
            break;
        case UCBasicBlockTypeExit:
            borderColor = [UIColor colorWithRed:0.75 green:0.20 blue:0.20 alpha:1.0];
            headerColor = [UIColor colorWithRed:0.92 green:0.65 blue:0.65 alpha:1.0];
            break;
        case UCBasicBlockTypeConditionalTrue:
            borderColor = [UIColor colorWithRed:0.20 green:0.65 blue:0.20 alpha:1.0];
            break;
        case UCBasicBlockTypeConditionalFalse:
            borderColor = [UIColor colorWithRed:0.70 green:0.20 blue:0.20 alpha:1.0];
            break;
        default:
            break;
    }
    view.layer.borderColor = borderColor.CGColor;
    
    UIView *headerBar = [[UIView alloc] init];
    headerBar.backgroundColor = headerColor;
    headerBar.tag = 100;
    [view addSubview:headerBar];
    
    UILabel *headerLabel = [[UILabel alloc] init];
    headerLabel.font = [UIFont boldSystemFontOfSize:9];
    headerLabel.textColor = [UIColor colorWithWhite:0.25 alpha:1.0];
    headerLabel.tag = 101;
    
    NSString *startAddr = [NSString stringWithFormat:@"%llx", block.startAddress];
    uint64_t endAddrVal = block.endAddress >= 4 ? block.endAddress - 4 : block.endAddress;
    NSString *endAddr = [NSString stringWithFormat:@"%llx", endAddrVal];
    if (startAddr.length < 8) startAddr = [@"0" stringByAppendingString:startAddr];
    if (endAddr.length < 8) endAddr = [@"0" stringByAppendingString:endAddr];
    
    headerLabel.text = [NSString stringWithFormat:@"loc_%@", startAddr];
    [headerBar addSubview:headerLabel];
    
    UCInstructionTextView *textView = [[UCInstructionTextView alloc] init];
    textView.backgroundColor = [UIColor colorWithWhite:0.09 alpha:1.0];
    textView.editable = NO;
    textView.scrollEnabled = NO;
    textView.textContainerInset = UIEdgeInsetsMake(4, 6, 4, 6);
    textView.textContainer.lineFragmentPadding = 0;
    textView.tag = 200;
    textView.lineInstructions = block.instructions;
    
    NSMutableAttributedString *attrText = [[NSMutableAttributedString alloc] init];
    for (UCDisasmInstruction *insn in block.instructions) {
        NSString *addr = [NSString stringWithFormat:@"%llx", insn.address];
        if (addr.length < 8) {
            addr = [addr stringByPaddingToLength:8 withString:@"0" startingAtIndex:0];
        }
        
        // Brightened for the dark card: these used to be dark grays meant to
        // sit on a white background.
        UIColor *mnemColor = [UIColor colorWithWhite:0.92 alpha:1.0];
        if (insn.isCall) {
            mnemColor = [UIColor colorWithRed:1.0 green:0.68 blue:0.30 alpha:1.0];
        } else if (insn.isReturn) {
            mnemColor = [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0];
        } else if (insn.isBranch) {
            mnemColor = [UIColor colorWithRed:0.45 green:0.85 blue:0.50 alpha:1.0];
        } else if (insn.isNop) {
            mnemColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        }

        NSAttributedString *addrAttr = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@  ", addr]
            attributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0],
                NSFontAttributeName: [UIFont fontWithName:@"Menlo-Regular" size:9]
            }];

        NSString *mnem = [(insn.mnemonic ?: @"") stringByPaddingToLength:8 withString:@" " startingAtIndex:0];
        NSAttributedString *mnemAttr = [[NSAttributedString alloc]
            initWithString:mnem
            attributes:@{
                NSForegroundColorAttributeName: mnemColor,
                NSFontAttributeName: [UIFont fontWithName:@"Menlo-Bold" size:9]
            }];

        NSString *opsText = insn.operands ?: @"";
        BOOL hasTrailingComment = (insn.comment.length > 0) || (insn.xrefComment.length > 0);
        NSAttributedString *opAttr = [[NSAttributedString alloc]
            initWithString:[NSString stringWithFormat:@"%@%@", opsText, hasTrailingComment ? @"" : @"\n"]
            attributes:@{
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:1.0],
                NSFontAttributeName: [UIFont fontWithName:@"Menlo-Regular" size:9]
            }];

        [attrText appendAttributedString:addrAttr];
        [attrText appendAttributedString:mnemAttr];
        [attrText appendAttributedString:opAttr];

        if (hasTrailingComment) {
            NSMutableString *commentText = [NSMutableString stringWithString:@"  "];
            if (insn.xrefComment.length > 0) {
                [commentText appendString:insn.xrefComment];
            }
            if (insn.comment.length > 0) {
                if (insn.xrefComment.length > 0) [commentText appendString:@"  "];
                [commentText appendFormat:@"; %@", insn.comment];
            }
            [commentText appendString:@"\n"];

            NSAttributedString *commentAttr = [[NSAttributedString alloc]
                initWithString:commentText
                attributes:@{
                    // Brightened for the dark card (was a dark olive meant for a white bg).
                    NSForegroundColorAttributeName: [UIColor colorWithRed:0.55 green:0.75 blue:0.55 alpha:1.0],
                    NSFontAttributeName: [UIFont fontWithName:@"Menlo-Italic" size:9] ?: [UIFont italicSystemFontOfSize:9]
                }];
            [attrText appendAttributedString:commentAttr];
        }
    }
    
    textView.attributedText = attrText;
    [view addSubview:textView];

    UITapGestureRecognizer *instructionTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(instructionTextTapped:)];
    [textView addGestureRecognizer:instructionTap];
    textView.userInteractionEnabled = YES;
    
    CGFloat blockWidth = 320;
    NSUInteger lineCount = block.instructions.count;
    CGFloat headerHeight = 18;
    CGFloat bodyHeight = lineCount * 13 + 8;
    CGFloat blockHeight = headerHeight + bodyHeight;
    
    view.frame = CGRectMake(0, 0, blockWidth, blockHeight);
    headerBar.frame = CGRectMake(0, 0, blockWidth, headerHeight);
    headerLabel.frame = CGRectMake(8, 2, blockWidth - 16, 14);
    textView.frame = CGRectMake(0, headerHeight, blockWidth, bodyHeight);
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(blockTapped:)];
    [view addGestureRecognizer:tap];
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(blockLongPressed:)];
    [view addGestureRecognizer:longPress];
    view.userInteractionEnabled = YES;
    view.tag = block.blockId;

    // Persistent loop marker: a block that sits on a back edge (loop header
    // or loop tail) gets a left-edge accent stripe that stays up all the
    // time, not just during the momentary tap highlight — so loops are
    // visible at a glance while scanning the whole graph.
    if ([self.loopBlockIds containsObject:@(block.blockId)]) {
        // A plain UIView, not a CALayer: CALayer has no -autoresizingMask on iOS
        // (that's a macOS-only AppKit/CALayer bridge thing — kCALayerHeightSizable
        // isn't even declared in the iOS SDK), so the layer version failed to
        // compile outright. UIView gives the same flexible-height auto-resize
        // behavior for free via UIViewAutoresizingFlexibleHeight.
        UIView *loopStripe = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3, view.bounds.size.height)];
        loopStripe.backgroundColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.1 alpha:1.0];
        loopStripe.autoresizingMask = UIViewAutoresizingFlexibleHeight;
        loopStripe.userInteractionEnabled = NO;
        [view addSubview:loopStripe];

        UILabel *loopBadge = [[UILabel alloc] init];
        loopBadge.text = @"↻"; // ↻
        loopBadge.font = [UIFont boldSystemFontOfSize:10];
        loopBadge.textColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.1 alpha:1.0];
        [loopBadge sizeToFit];
        loopBadge.frame = CGRectMake(blockWidth - loopBadge.frame.size.width - 6, 2, loopBadge.frame.size.width, 14);
        [headerBar addSubview:loopBadge];
    }

    return view;
}

- (void)instructionTextTapped:(UITapGestureRecognizer *)gesture {
    UCInstructionTextView *textView = (UCInstructionTextView *)gesture.view;
    if (![textView isKindOfClass:[UCInstructionTextView class]]) return;
    if (textView.lineInstructions.count == 0) return;

    CGPoint location = [gesture locationInView:textView];
    NSLayoutManager *layoutManager = textView.layoutManager;
    NSUInteger charIndex = [layoutManager characterIndexForPoint:location
                                                  inTextContainer:textView.textContainer
                         fractionOfDistanceBetweenInsertionPoints:NULL];

    if (charIndex >= textView.textStorage.length) return;

    // createBlockView: emits exactly one rendered line per instruction, so
    // counting newlines up to the tap point gives the instruction index.
    NSString *plainText = textView.text;
    NSUInteger lineIndex = 0;
    for (NSUInteger i = 0; i < charIndex && i < plainText.length; i++) {
        if ([plainText characterAtIndex:i] == '\n') lineIndex++;
    }

    if (lineIndex >= textView.lineInstructions.count) return;
    UCDisasmInstruction *insn = textView.lineInstructions[lineIndex];

    if (self.instructionTapHandler) {
        self.instructionTapHandler(insn);
    }
}

- (void)blockTapped:(UITapGestureRecognizer *)gesture {
    UIView *blockView = gesture.view;
    NSInteger blockId = blockView.tag;

    for (UCBasicBlock *block in self.basicBlocks) {
        if (block.blockId == blockId) {
            if (self.blockTapHandler) {
                self.blockTapHandler(block);
            }
            break;
        }
    }
}

- (void)blockLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIView *blockView = gesture.view;
    NSInteger blockId = blockView.tag;

    for (UCBasicBlock *block in self.basicBlocks) {
        if (block.blockId == blockId) {
            if (self.blockLongPressHandler) {
                self.blockLongPressHandler(block);
            }
            break;
        }
    }
}

/// Walks the CFG with the same iterative DFS `layoutGraph` uses (so it finds
/// exactly the same back edges), but only to answer "which blocks sit on a
/// loop" — no positioning. Run before block views are built so
/// `createBlockView:` can add a persistent loop marker on the first pass
/// instead of a second patch-up pass over every view.
- (NSSet<NSNumber *> *)computeLoopBlockIds {
    if (self.basicBlocks.count == 0) return [NSSet set];

    UCBasicBlock *entryBlock = nil;
    for (UCBasicBlock *block in self.basicBlocks) {
        if (block.type == UCBasicBlockTypeEntry || block.predecessors.count == 0) {
            entryBlock = block;
            break;
        }
    }
    if (!entryBlock) entryBlock = self.basicBlocks.firstObject;

    NSMutableArray *stack = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableSet *onStack = [NSMutableSet set];
    NSMutableSet<NSNumber *> *loopIds = [NSMutableSet set];

    [stack addObject:entryBlock];
    [onStack addObject:@(entryBlock.blockId)];

    while (stack.count > 0) {
        UCBasicBlock *current = stack.lastObject;
        NSNumber *curId = @(current.blockId);

        if ([visited containsObject:curId]) {
            [stack removeLastObject];
            [onStack removeObject:curId];
            continue;
        }
        [visited addObject:curId];

        for (UCBasicBlock *succ in current.successors) {
            NSNumber *succId = @(succ.blockId);
            if ([visited containsObject:succId] && [onStack containsObject:succId]) {
                [loopIds addObject:curId];
                [loopIds addObject:succId];
                continue;
            }
            if (![visited containsObject:succId]) {
                [stack addObject:succ];
                [onStack addObject:succId];
            }
        }
    }

    return loopIds;
}

- (void)layoutGraph {
    if (self.basicBlocks.count == 0) return;

    NSMutableDictionary<NSNumber *, NSNumber *> *levelMap = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSMutableArray<NSNumber *> *> *levelBlocks = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *backEdges = [NSMutableSet set];
    
    UCBasicBlock *entryBlock = nil;
    for (UCBasicBlock *block in self.basicBlocks) {
        if (block.type == UCBasicBlockTypeEntry || block.predecessors.count == 0) {
            entryBlock = block;
            break;
        }
    }
    if (!entryBlock) entryBlock = self.basicBlocks.firstObject;
    
    NSMutableArray *stack = [NSMutableArray array];
    NSMutableSet *visited = [NSMutableSet set];
    NSMutableSet *onStack = [NSMutableSet set];
    
    [stack addObject:entryBlock];
    [onStack addObject:@(entryBlock.blockId)];
    levelMap[@(entryBlock.blockId)] = @0;
    
    while (stack.count > 0) {
        UCBasicBlock *current = stack.lastObject;
        NSNumber *curId = @(current.blockId);
        
        if ([visited containsObject:curId]) {
            [stack removeLastObject];
            [onStack removeObject:curId];
            continue;
        }
        [visited addObject:curId];
        
        NSInteger currentLevel = [levelMap[curId] integerValue];
        
        if (!levelBlocks[@(currentLevel)]) {
            levelBlocks[@(currentLevel)] = [NSMutableArray array];
        }
        if (![levelBlocks[@(currentLevel)] containsObject:curId]) {
            [levelBlocks[@(currentLevel)] addObject:curId];
        }
        
        for (UCBasicBlock *succ in current.successors) {
            NSNumber *succId = @(succ.blockId);

            if ([visited containsObject:succId] && [onStack containsObject:succId]) {
                NSString *edgeKey = [NSString stringWithFormat:@"%ld->%ld", (long)current.blockId, (long)succ.blockId];
                [backEdges addObject:edgeKey];
                continue;
            }

            NSNumber *existingLevel = levelMap[succId];
            NSInteger newLevel = currentLevel + 1;
            if (!existingLevel || [existingLevel integerValue] < newLevel) {
                levelMap[succId] = @(newLevel);
            }

            if (![visited containsObject:succId]) {
                [stack addObject:succ];
                [onStack addObject:succId];
            }
        }
    }
    
    for (UCBasicBlock *block in self.basicBlocks) {
        NSNumber *bid = @(block.blockId);
        if (!levelMap[bid]) {
            NSInteger maxLevel = 0;
            for (NSNumber *l in levelMap.allValues) {
                maxLevel = MAX(maxLevel, l.integerValue);
            }
            levelMap[bid] = @(maxLevel + 1);
            if (!levelBlocks[@(maxLevel + 1)]) {
                levelBlocks[@(maxLevel + 1)] = [NSMutableArray array];
            }
            [levelBlocks[@(maxLevel + 1)] addObject:bid];
        }
    }
    
    CGFloat horizontalGap = 40;
    CGFloat verticalGap = 60;
    CGFloat blockWidth = 320;
    
    NSInteger maxLevel = 0;
    for (NSNumber *l in levelMap.allValues) {
        maxLevel = MAX(maxLevel, l.integerValue);
    }
    
    NSArray *sortedLevels = [levelBlocks.allKeys sortedArrayUsingSelector:@selector(compare:)];
    
    CGFloat maxLevelWidth = 0;
    for (NSNumber *level in sortedLevels) {
        NSArray *blocks = levelBlocks[level];
        CGFloat levelWidth = blocks.count * blockWidth + (blocks.count - 1) * horizontalGap;
        maxLevelWidth = MAX(maxLevelWidth, levelWidth);
    }
    CGFloat totalWidth = maxLevelWidth + horizontalGap * 3;
    
    CGFloat totalHeight = verticalGap * 2;
    for (NSNumber *level in sortedLevels) {
        NSArray *blocks = levelBlocks[level];
        CGFloat levelMaxHeight = 0;
        for (NSNumber *bid in blocks) {
            UIView *bv = self.blockViewMap[bid];
            if (!bv) continue;
            levelMaxHeight = MAX(levelMaxHeight, bv.frame.size.height);
        }
        totalHeight += levelMaxHeight + verticalGap;
    }
    
    self.frame = CGRectMake(0, 0, totalWidth, totalHeight);
    self.bgGradient.frame = self.bounds;
    
    CGFloat currentY = verticalGap;
    
    for (NSNumber *level in sortedLevels) {
        NSArray *blockIds = levelBlocks[level];
        CGFloat levelMaxHeight = 0;
        for (NSNumber *bid in blockIds) {
            UIView *bv = self.blockViewMap[bid];
            if (!bv) continue;
            levelMaxHeight = MAX(levelMaxHeight, bv.frame.size.height);
        }

        CGFloat levelWidth = blockIds.count * blockWidth + (blockIds.count - 1) * horizontalGap;
        CGFloat startX = (totalWidth - levelWidth) / 2;
        
        for (NSUInteger i = 0; i < blockIds.count; i++) {
            NSNumber *bid = blockIds[i];
            UIView *bv = self.blockViewMap[bid];
            if (!bv) continue;
            CGRect frame = bv.frame;
            frame.origin.x = startX + i * (blockWidth + horizontalGap);
            frame.origin.y = currentY;
            bv.frame = frame;
        }
        
        currentY += levelMaxHeight + verticalGap;
    }
    
    [self drawEdges:backEdges];
}

- (void)drawEdges:(NSSet<NSString *> *)backEdges {
    for (CALayer *l in self.edgeLayers) [l removeFromSuperlayer];
    [self.edgeLayers removeAllObjects];
    
    for (UCBasicBlock *block in self.basicBlocks) {
        UIView *fromView = self.blockViewMap[@(block.blockId)];
        if (!fromView) continue;
        
        for (UCBasicBlock *succ in block.successors) {
            UIView *toView = self.blockViewMap[@(succ.blockId)];
            if (!toView) continue;
            
            NSString *edgeKey = [NSString stringWithFormat:@"%ld->%ld", (long)block.blockId, (long)succ.blockId];
            BOOL isBackEdge = [backEdges containsObject:edgeKey];
            
            UIColor *lineColor;
            if (isBackEdge) {
                lineColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.1 alpha:1.0];
            } else if (succ.type == UCBasicBlockTypeConditionalTrue) {
                lineColor = [UIColor colorWithRed:0.2 green:0.7 blue:0.2 alpha:1.0];
            } else if (succ.type == UCBasicBlockTypeConditionalFalse) {
                lineColor = [UIColor colorWithRed:0.8 green:0.2 blue:0.2 alpha:1.0];
            } else {
                // Default/unconditional edges now use the app's real accent
                // color instead of a hardcoded blue, so the whole graph
                // reads as an AirShare feature.
                lineColor = AVX512Color.appAccentColor;
            }
            
            [self drawEdgeFrom:fromView to:toView color:lineColor isBackEdge:isBackEdge];
        }
    }
}

- (void)drawEdgeFrom:(UIView *)fromView to:(UIView *)toView color:(UIColor *)color isBackEdge:(BOOL)isBackEdge {
    CGFloat fromX, fromY, toX, toY;
    
    if (isBackEdge) {
        fromX = CGRectGetMidX(fromView.frame);
        fromY = CGRectGetMinY(fromView.frame);
        toX = CGRectGetMidX(toView.frame);
        toY = CGRectGetMaxY(toView.frame);
        
        CGFloat offset = -60;
        CGFloat sideX = MIN(fromX, toX) + offset;
        
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(fromX, fromY)];
        [path addLineToPoint:CGPointMake(fromX, fromY - 15)];
        [path addCurveToPoint:CGPointMake(sideX, (fromY + toY) / 2)
                controlPoint1:CGPointMake(fromX - 20, fromY - 15)
                controlPoint2:CGPointMake(sideX, fromY - 15)];
        [path addCurveToPoint:CGPointMake(toX, toY + 15)
                controlPoint1:CGPointMake(sideX, toY + 15)
                controlPoint2:CGPointMake(toX - 20, toY + 15)];
        [path addLineToPoint:CGPointMake(toX, toY)];
        
        [self addEdgeLayer:path color:color arrowAt:CGPointMake(toX, toY) directionUp:YES];
    } else {
        fromX = CGRectGetMidX(fromView.frame);
        fromY = CGRectGetMaxY(fromView.frame);
        toX = CGRectGetMidX(toView.frame);
        toY = CGRectGetMinY(toView.frame);
        
        CGFloat midY = (fromY + toY) / 2;
        
        UIBezierPath *path = [UIBezierPath bezierPath];
        [path moveToPoint:CGPointMake(fromX, fromY)];
        
        if (fabs(toX - fromX) < 20) {
            [path addLineToPoint:CGPointMake(toX, toY - 6)];
        } else {
            CGFloat cpOffset = (toY - fromY) * 0.4;
            [path addCurveToPoint:CGPointMake(toX, toY - 6)
                    controlPoint1:CGPointMake(fromX, fromY + cpOffset)
                    controlPoint2:CGPointMake(toX, toY - cpOffset)];
        }
        
        [self addEdgeLayer:path color:color arrowAt:CGPointMake(toX, toY) directionUp:NO];
    }
}

- (void)addEdgeLayer:(UIBezierPath *)path color:(UIColor *)color arrowAt:(CGPoint)arrowPos directionUp:(BOOL)up {
    CAShapeLayer *shapeLayer = [CAShapeLayer layer];
    shapeLayer.path = path.CGPath;
    shapeLayer.strokeColor = color.CGColor;
    shapeLayer.fillColor = [UIColor clearColor].CGColor;
    shapeLayer.lineWidth = 1.5;
    shapeLayer.lineCap = kCALineCapRound;
    
    CGFloat arrowSize = 8;
    UIBezierPath *arrowPath = [UIBezierPath bezierPath];
    [arrowPath moveToPoint:arrowPos];
    if (up) {
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x - arrowSize / 2, arrowPos.y + arrowSize)];
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x + arrowSize / 2, arrowPos.y + arrowSize)];
    } else {
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x - arrowSize / 2, arrowPos.y - arrowSize)];
        [arrowPath addLineToPoint:CGPointMake(arrowPos.x + arrowSize / 2, arrowPos.y - arrowSize)];
    }
    [arrowPath closePath];
    
    CAShapeLayer *arrowLayer = [CAShapeLayer layer];
    arrowLayer.path = arrowPath.CGPath;
    arrowLayer.fillColor = color.CGColor;
    
    [self.layer addSublayer:shapeLayer];
    [self.layer addSublayer:arrowLayer];
    [self.edgeLayers addObject:shapeLayer];
    [self.edgeLayers addObject:arrowLayer];
}

@end

#pragma mark - UCFuncListViewController

@interface UCFuncListViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) NSArray<UCFunction *> *allFunctions;
@property (nonatomic, strong) NSArray<UCFunction *> *filteredFunctions;

@end

@implementation UCFuncListViewController

- (instancetype)initWithFunctions:(NSArray<UCFunction *> *)functions {
    self = [super init];
    if (self) {
        _allFunctions = functions;
        _filteredFunctions = functions;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AVX512Color.primaryBackgroundColor;
    self.title = @"Function function list of functions for the";
    
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];
    
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"Search search function functions name of the searching...";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.tableHeaderView = self.searchBar;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"FuncCell"];
    
    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.frame = self.view.bounds;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredFunctions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FuncCell" forIndexPath:indexPath];
    UCFunction *func = self.filteredFunctions[indexPath.row];
    
    cell.textLabel.text = func.name;
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:12];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"0x%llx  %lu bytes  %lu blocks",
                                  func.startAddress, (unsigned long)func.size, (unsigned long)func.basicBlockCount];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    UCFunction *func = self.filteredFunctions[indexPath.row];
    UCDisasmViewController *disasmVC = [[UCDisasmViewController alloc] initWithFunction:func title:func.name];
    [self.navigationController pushViewController:disasmVC animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.filteredFunctions = self.allFunctions;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"name contains[c] %@", searchText];
        self.filteredFunctions = [self.allFunctions filteredArrayUsingPredicate:pred];
    }
    [self.tableView reloadData];
}

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end


#pragma mark - UCDisassemblerBrowserViewController

@interface UCDisassemblerBrowserViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UCFunction *function;
@property (nonatomic, copy) NSString *browserTitle;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSArray<UCDisasmInstruction *> *visibleInstructions;
@property (nonatomic, assign) uint64_t highlightAddress;
@property (nonatomic, assign) BOOL hasScrolledToHighlight;
@end

@implementation UCDisassemblerBrowserViewController

- (instancetype)initWithFunction:(UCFunction *)function title:(NSString *)title {
    return [self initWithFunction:function title:title highlightAddress:0];
}

- (instancetype)initWithFunction:(UCFunction *)function
                           title:(NSString *)title
                highlightAddress:(uint64_t)highlightAddress {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _function = function;
        _browserTitle = title.length ? [title copy] : (function.name ?: @"Disassembler");
        _visibleInstructions = function.instructions ?: @[];
        _highlightAddress = highlightAddress;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.title = self.browserTitle;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"More"
                                                                                style:UIBarButtonItemStylePlain
                                                                               target:self
                                                                               action:@selector(showFunctionActions)];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search address, opcode, symbol, class, string…";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = [UIColor blackColor];
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68.0;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Instruction"];
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.highlightAddress == 0 || self.hasScrolledToHighlight) return;
    self.hasScrolledToHighlight = YES;

    NSUInteger row = [self.visibleInstructions indexOfObjectPassingTest:^BOOL(UCDisasmInstruction *insn, NSUInteger idx, BOOL *stop) {
        return insn.address == self.highlightAddress;
    }];
    if (row == NSNotFound) return;

    NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
    [self.tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:YES];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = [searchController.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    if (!q.length) {
        self.visibleInstructions = self.function.instructions ?: @[];
    } else {
        NSMutableArray *matches = [NSMutableArray array];
        for (UCDisasmInstruction *insn in self.function.instructions) {
            NSString *address = [NSString stringWithFormat:@"0x%llx", insn.address];
            NSString *haystack = [NSString stringWithFormat:@"%@ %@ %@ %@ %@ %@",
                                  address,
                                  insn.fullText ?: @"",
                                  insn.comment ?: @"",
                                  insn.xrefComment ?: @"",
                                  insn.functionName ?: @"",
                                  insn.bytesHex ?: @""].lowercaseString;
            if ([haystack containsString:q]) [matches addObject:insn];
        }
        self.visibleInstructions = matches;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleInstructions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Instruction" forIndexPath:indexPath];
    UCDisasmInstruction *insn = self.visibleInstructions[indexPath.row];
    // Persistent sync highlight: when this list was opened from a tapped CFG
    // block, the row for that block's start address stays tinted so it's
    // obvious where the graph selection landed in the linear view, not just
    // a one-time scroll with nothing to show for it once you start scrolling.
    BOOL isSyncedRow = (self.highlightAddress != 0 && insn.address == self.highlightAddress);
    cell.backgroundColor = isSyncedRow
        ? [UIColor colorWithRed:0.30 green:0.22 blue:0.03 alpha:1.0]
        : [UIColor blackColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    NSString *address = [NSString stringWithFormat:@"0x%llx", insn.address];
    NSString *bytes = insn.bytesHex ?: @"";
    NSString *instruction = insn.fullText ?: @"???";
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@   %@\n", address, bytes]
                                                                   attributes:@{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular], NSForegroundColorAttributeName:[UIColor colorWithRed:0.35 green:0.7 blue:1 alpha:1]}]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:instruction
                                                                   attributes:@{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium], NSForegroundColorAttributeName:[UIColor whiteColor]}]];
    NSString *annotation = insn.comment.length ? insn.comment : insn.xrefComment;
    if (insn.functionName.length) {
        annotation = annotation.length ? [NSString stringWithFormat:@"%@  •  %@", insn.functionName, annotation] : insn.functionName;
    }
    if (annotation.length) {
        [text appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"\n%@", annotation]
                                                                       attributes:@{NSFontAttributeName:[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular], NSForegroundColorAttributeName:[UIColor colorWithWhite:0.65 alpha:1]}]];
    }
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.attributedText = text;
    cell.accessoryType = insn.isBranch ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UCDisasmInstruction *insn = self.visibleInstructions[indexPath.row];
    UIAlertController *actions = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"0x%llx", insn.address]
                                                                       message:insn.fullText
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
    [actions addAction:[UIAlertAction actionWithTitle:@"Copy Instruction" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = insn.fullText ?: @"";
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Copy Address" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"0x%llx", insn.address];
    }]];
    if (insn.branchTarget) {
        [actions addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Copy Target 0x%llx", insn.branchTarget]
                                                     style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"0x%llx", insn.branchTarget];
        }]];
    }
    if (insn.xrefFrom.count) {
        [actions addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"XREFs (%lu)", (unsigned long)insn.xrefFrom.count]
                                                     style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            UCXrefListViewController *vc = [[UCXrefListViewController alloc] initWithTargetAddress:insn.address sourceAddresses:insn.xrefFrom];
            [self.navigationController pushViewController:vc animated:YES];
        }]];
    }
    [actions addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        actions.popoverPresentationController.sourceView = tableView;
        actions.popoverPresentationController.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:actions animated:YES completion:nil];
}

- (void)showFunctionActions {
    UIAlertController *actions = [UIAlertController alertControllerWithTitle:self.function.name ?: @"Function"
                                                                       message:[NSString stringWithFormat:@"0x%llx – 0x%llx\n%lu instructions · %lu blocks", self.function.startAddress, self.function.endAddress, (unsigned long)self.function.instructions.count, (unsigned long)self.function.basicBlocks.count]
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
    [actions addAction:[UIAlertAction actionWithTitle:@"Open CFG Viewer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UCDisasmViewController *vc = [[UCDisasmViewController alloc] initWithFunction:self.function title:self.function.name];
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Open Pseudocode" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = [UCPseudocodeViewController pseudocodeForFunction:self.function];
        UCPseudocodeViewController *vc = [[UCPseudocodeViewController alloc] initWithPseudocode:text title:@"Pseudocode"];
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Open Analysis Center" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UCAnalysisCenterViewController *vc = [[UCAnalysisCenterViewController alloc] initWithFunction:self.function];
        [self.navigationController pushViewController:vc animated:YES];
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Copy Function Address" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"0x%llx", self.function.startAddress];
    }]];
    [actions addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        actions.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:actions animated:YES completion:nil];
}

@end
