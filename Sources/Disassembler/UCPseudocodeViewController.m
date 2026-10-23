
#import "UCPseudocodeViewController.h"
#import "AVX512Color.h"

@interface UCPseudocodeViewController ()

@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, copy) NSString *pseudocode;
@property (nonatomic, copy) NSString *navTitle;

@end


#pragma mark - Linear ARM64 pseudocode

static NSString *UCPseudoOperandText(UCDisasmOperand *operand) {
    if (!operand) return @"value";
    if (operand.type == UCDisasmOperandTypeRegister ||
        operand.type == UCDisasmOperandTypeFPRegister) {
        return operand.registerName.length ? operand.registerName : operand.text;
    }
    if (operand.type == UCDisasmOperandTypeImmediate) {
        return [NSString stringWithFormat:@"0x%llx", operand.immediateValue];
    }
    if (operand.type == UCDisasmOperandTypeMemory) {
        NSString *base = operand.memoryBaseReg.length ? operand.memoryBaseReg : @"sp";
        if (operand.memoryOffset == 0) return [NSString stringWithFormat:@"[%@]", base];
        if (operand.memoryOffset > 0) return [NSString stringWithFormat:@"[%@ + 0x%llx]", base, (uint64_t)operand.memoryOffset];
        return [NSString stringWithFormat:@"[%@ - 0x%llx]", base, (uint64_t)(-operand.memoryOffset)];
    }
    return operand.text.length ? operand.text : @"value";
}

static NSString *UCPseudoCondition(NSString *mnemonic) {
    NSString *lower = mnemonic.lowercaseString;
    NSRange dot = [lower rangeOfString:@"."];
    if (dot.location == NSNotFound || dot.location + 1 >= lower.length) return nil;
    NSString *cc = [lower substringFromIndex:dot.location + 1];
    return @{
        @"eq": @"==", @"ne": @"!=",
        @"lt": @"<", @"le": @"<=",
        @"gt": @">", @"ge": @">=",
        @"hs": @">=", @"cs": @">=",
        @"lo": @"<", @"cc": @"<",
        @"hi": @">", @"ls": @"<=",
        @"mi": @"< 0", @"pl": @">= 0"
    }[cc];
}

static NSString *UCPseudoLabel(uint64_t address) {
    return [NSString stringWithFormat:@"loc_%llx", address];
}

static NSString *UCPseudoInlineComment(UCDisasmInstruction *insn) {
    NSMutableArray *parts = [NSMutableArray array];
    if (insn.comment.length) [parts addObject:insn.comment];
    if (insn.xrefComment.length) [parts addObject:insn.xrefComment];
    if (!parts.count) return @"";
    return [NSString stringWithFormat:@" /* %@ */", [parts componentsJoinedByString:@" "]];
}

static NSString *UCPseudoCallName(UCDisasmInstruction *insn) {
    NSString *name = insn.comment.length ? insn.comment : nil;
    if (!name.length && insn.branchTarget) name = [NSString stringWithFormat:@"sub_%llx", insn.branchTarget];
    if (!name.length) name = @"call_target";
    name = [name stringByReplacingOccurrencesOfString:@"[" withString:@""];
    name = [name stringByReplacingOccurrencesOfString:@"]" withString:@""];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return name;
}

static NSString *UCPseudoFunctionName(NSString *name, uint64_t address) {
    NSString *result = name.length ? name : [NSString stringWithFormat:@"sub_%llx", address];
    result = [result stringByReplacingOccurrencesOfString:@"[" withString:@""];
    result = [result stringByReplacingOccurrencesOfString:@"]" withString:@""];
    result = [result stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    return result;
}

@implementation UCPseudocodeViewController

+ (NSString *)pseudocodeForFunction:(UCFunction *)function {
    if (!function) return @"// No function selected.\n";

    NSArray<UCBasicBlock *> *blocks =
        [function.basicBlocks sortedArrayUsingComparator:^NSComparisonResult(UCBasicBlock *a, UCBasicBlock *b) {
            if (a.startAddress < b.startAddress) return NSOrderedAscending;
            if (a.startAddress > b.startAddress) return NSOrderedDescending;
            return NSOrderedSame;
        }];

    NSString *name = UCPseudoFunctionName(function.name, function.startAddress);
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"// Linear pseudocode — ARM64 CFG preserved with goto edges\n"];
    [out appendFormat:@"// Function: %@ @ 0x%llx (%lu bytes, %lu blocks)\n\n",
     function.name ?: name, function.startAddress, (unsigned long)function.size, (unsigned long)blocks.count];
    [out appendFormat:@"void %@() {\n", name];

    for (UCBasicBlock *block in blocks) {
        [out appendFormat:@"\nloc_%llx:\n", block.startAddress];

        NSString *lastCompare = nil;

        for (UCDisasmInstruction *insn in block.instructions) {
            NSString *mnemonic = insn.mnemonic.lowercaseString ?: @"";
            NSArray<UCDisasmOperand *> *ops = insn.operandList ?: @[];
            NSString *statement = nil;

            if (insn.isNop || [mnemonic isEqualToString:@"nop"]) continue;

            if ([mnemonic isEqualToString:@"cmp"] || [mnemonic isEqualToString:@"cmn"]) {
                if (ops.count >= 2) {
                    NSString *lhs = UCPseudoOperandText(ops[0]);
                    NSString *rhs = UCPseudoOperandText(ops[1]);
                    lastCompare = [NSString stringWithFormat:@"%@ %@ %@",
                                   lhs, [mnemonic isEqualToString:@"cmn"] ? @"+" : @"-", rhs];
                } else {
                    lastCompare = insn.operands ?: @"flags";
                }
                continue;
            }

            if ([mnemonic isEqualToString:@"mov"] || [mnemonic isEqualToString:@"movz"] ||
                [mnemonic isEqualToString:@"movn"] || [mnemonic isEqualToString:@"movk"]) {
                if (ops.count >= 2) {
                    statement = [NSString stringWithFormat:@"%@ = %@", UCPseudoOperandText(ops[0]), UCPseudoOperandText(ops[1])];
                }
            } else if ([mnemonic isEqualToString:@"add"] || [mnemonic isEqualToString:@"adds"] ||
                       [mnemonic isEqualToString:@"sub"] || [mnemonic isEqualToString:@"subs"] ||
                       [mnemonic isEqualToString:@"mul"]) {
                if (ops.count >= 3) {
                    NSString *op = [mnemonic hasPrefix:@"sub"] ? @"-" :
                                   [mnemonic isEqualToString:@"mul"] ? @"*" : @"+";
                    statement = [NSString stringWithFormat:@"%@ = %@ %@ %@",
                                 UCPseudoOperandText(ops[0]), UCPseudoOperandText(ops[1]),
                                 op, UCPseudoOperandText(ops[2])];
                }
            } else if ([mnemonic isEqualToString:@"madd"] && ops.count >= 4) {
                statement = [NSString stringWithFormat:@"%@ = (%@ * %@) + %@",
                             UCPseudoOperandText(ops[0]), UCPseudoOperandText(ops[1]),
                             UCPseudoOperandText(ops[2]), UCPseudoOperandText(ops[3])];
            } else if ([mnemonic isEqualToString:@"and"] || [mnemonic isEqualToString:@"orr"] ||
                       [mnemonic isEqualToString:@"eor"]) {
                if (ops.count >= 3) {
                    NSString *op = [mnemonic isEqualToString:@"and"] ? @"&" :
                                   [mnemonic isEqualToString:@"orr"] ? @"|" : @"^";
                    statement = [NSString stringWithFormat:@"%@ = %@ %@ %@",
                                 UCPseudoOperandText(ops[0]), UCPseudoOperandText(ops[1]),
                                 op, UCPseudoOperandText(ops[2])];
                }
            } else if ([mnemonic isEqualToString:@"ldr"] || [mnemonic isEqualToString:@"ldrb"] ||
                       [mnemonic isEqualToString:@"ldrh"] || [mnemonic isEqualToString:@"ldrsw"]) {
                if (ops.count >= 2) {
                    NSString *type = [mnemonic isEqualToString:@"ldrb"] ? @"uint8_t" :
                                     [mnemonic isEqualToString:@"ldrh"] ? @"uint16_t" :
                                     [mnemonic isEqualToString:@"ldrsw"] ? @"int32_t" : @"uint64_t";
                    statement = [NSString stringWithFormat:@"%@ = *(%@ *)(%@)",
                                 UCPseudoOperandText(ops[0]), type, UCPseudoOperandText(ops[1])];
                }
            } else if ([mnemonic isEqualToString:@"str"] || [mnemonic isEqualToString:@"strb"] ||
                       [mnemonic isEqualToString:@"strh"]) {
                if (ops.count >= 2) {
                    NSString *type = [mnemonic isEqualToString:@"strb"] ? @"uint8_t" :
                                     [mnemonic isEqualToString:@"strh"] ? @"uint16_t" : @"uint64_t";
                    statement = [NSString stringWithFormat:@"*(%@ *)(%@) = %@",
                                 type, UCPseudoOperandText(ops[1]), UCPseudoOperandText(ops[0])];
                }
            } else if ([mnemonic isEqualToString:@"adrp"] || [mnemonic isEqualToString:@"adr"]) {
                if (ops.count >= 2) {
                    statement = [NSString stringWithFormat:@"%@ = 0x%llx",
                                 UCPseudoOperandText(ops[0]), ops[1].immediateValue];
                }
            } else if ([mnemonic isEqualToString:@"bl"] || insn.isCall) {
                statement = [NSString stringWithFormat:@"%@();", UCPseudoCallName(insn)];
            } else if ([mnemonic isEqualToString:@"blr"]) {
                statement = [NSString stringWithFormat:@"%@();", ops.count ? UCPseudoOperandText(ops[0]) : @"call_reg"];
            } else if ([mnemonic isEqualToString:@"cbz"] || [mnemonic isEqualToString:@"cbnz"]) {
                if (ops.count >= 1 && insn.branchTarget) {
                    NSString *cmpOp = [mnemonic isEqualToString:@"cbz"] ? @"==" : @"!=";
                    statement = [NSString stringWithFormat:@"if (%@ %@ 0) goto %@;",
                                 UCPseudoOperandText(ops[0]), cmpOp, UCPseudoLabel(insn.branchTarget)];
                }
            } else if ([mnemonic hasPrefix:@"b."]) {
                NSString *cond = UCPseudoCondition(mnemonic);
                if (insn.branchTarget) {
                    NSString *expr = lastCompare.length ? lastCompare : @"condition";
                    if (cond.length) {
                        NSArray *parts = [expr componentsSeparatedByString:@" "];
                        if (parts.count >= 3 &&
                            ([cond isEqualToString:@"=="] || [cond isEqualToString:@"!="] ||
                             [cond isEqualToString:@"<"] || [cond isEqualToString:@"<="] ||
                             [cond isEqualToString:@">"] || [cond isEqualToString:@">="])) {
                            expr = [NSString stringWithFormat:@"%@ %@ %@", parts[0], cond, parts[2]];
                        } else if ([cond isEqualToString:@"< 0"] || [cond isEqualToString:@">= 0"]) {
                            expr = [NSString stringWithFormat:@"flags %@", cond];
                        }
                    }
                    statement = [NSString stringWithFormat:@"if (%@) goto %@;", expr, UCPseudoLabel(insn.branchTarget)];
                }
            } else if ([mnemonic isEqualToString:@"b"] || insn.isUnconditionalBranch) {
                if (insn.branchTarget) statement = [NSString stringWithFormat:@"goto %@;", UCPseudoLabel(insn.branchTarget)];
            } else if ([mnemonic isEqualToString:@"ret"]) {
                statement = @"return x0;";
            } else if ([mnemonic isEqualToString:@"stp"] || [mnemonic isEqualToString:@"ldp"]) {
                statement = [NSString stringWithFormat:@"// %@ %@", insn.mnemonic ?: @"", insn.operands ?: @""];
            } else {
                statement = [NSString stringWithFormat:@"// %@ %@", insn.mnemonic ?: @"", insn.operands ?: @""];
            }

            if (statement.length) [out appendFormat:@"    %@%@\n", statement, UCPseudoInlineComment(insn)];
        }

        UCDisasmInstruction *last = block.instructions.lastObject;
        if (last && !last.isReturn && !last.isBranch && block.successors.count == 1) {
            [out appendFormat:@"    goto %@;\n", UCPseudoLabel(block.successors.firstObject.startAddress)];
        } else if (last && !last.isReturn && block.successors.count > 1) {
            UCBasicBlock *fallthrough = block.successors.lastObject;
            [out appendFormat:@"    else goto %@;\n", UCPseudoLabel(fallthrough.startAddress)];
        }
    }

    [out appendString:@"}\n"];
    return out;
}


- (instancetype)initWithPseudocode:(NSString *)pseudocode title:(NSString *)title {
    self = [super init];
    if (self) {
        _pseudocode = pseudocode ?: @"";
        _navTitle = title ?: @"A false code-code counterfeiting";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AVX512Color.primaryBackgroundColor;
    self.title = self.navTitle;
    
    [self setupNavigationBar];
    [self setupTextView];
}

- (void)setupNavigationBar {
    UIBarButtonItem *done = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];
    
    UIBarButtonItem *copy = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
        target:self
        action:@selector(copyAction)];
    
    self.navigationItem.rightBarButtonItems = @[done, copy];
}

- (void)setupTextView {
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.font = [UIFont fontWithName:@"Menlo-Regular" size:12];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.backgroundColor = [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1.0];
    self.textView.textColor = [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0];
    self.textView.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
    self.textView.text = self.pseudocode;
    
    [self.view addSubview:self.textView];
}

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyAction {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Options options to the option"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy All"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
        pasteboard.string = self.pseudocode;
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.lastObject;
    [self presentViewController:alert animated:YES completion:nil];
}

@end
