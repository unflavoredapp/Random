#import "UCAnalysisCenterViewController.h"
#import "UCDisasmViewController.h"
#import "UCPseudocodeViewController.h"
#import "UCXrefListViewController.h"
#import "UCStringsBrowserViewController.h"
#import "UCFunctionExplorerViewController.h"
#import "UCAnalysisSelection.h"
#import "AVX512Color.h"

@interface UCAnalysisCenterViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property(nonatomic,strong) UCFunction *function;
@property(nonatomic,strong) UISegmentedControl *segments;
@property(nonatomic,strong) UITableView *tableView;
@property(nonatomic,strong) UISearchController *searchController;
@property(nonatomic,copy) NSArray *rows;
@property(nonatomic,copy) NSArray *allRows;
@property(nonatomic,copy) NSString *mode;
@property(nonatomic,strong) NSMutableData *patchBytes;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *patches;
@end

@implementation UCAnalysisCenterViewController

- (instancetype)initWithFunction:(UCFunction *)function {
    self = [super init];
    if (self) {
        _function = function;
        _mode = @"Overview";
        _patchBytes = [NSMutableData data];
        _patches = [NSMutableArray array];
        for (UCDisasmInstruction *i in function.instructions ?: @[]) {
            NSArray *parts = [i.bytesHex componentsSeparatedByString:@" "];
            for (NSString *p in parts) {
                unsigned int b = 0;
                if ([[NSScanner scannerWithString:p] scanHexInt:&b]) {
                    uint8_t v = (uint8_t)b; [_patchBytes appendBytes:&v length:1];
                }
            }
        }
        [self rebuildRows];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.title = @"Analysis Center";

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Navigate" style:UIBarButtonItemStylePlain target:self action:@selector(navigate)];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(selectionChanged:) name:UCAnalysisSelectionDidChangeNotification object:nil];

    NSArray *titles = @[@"Overview", @"Strings", @"Symbols", @"Functions", @"Graph", @"Flow", @"Memory", @"Patch", @"Diff"];
    self.segments = [[UISegmentedControl alloc] initWithItems:titles];
    self.segments.selectedSegmentIndex = 0;
    [self.segments addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.segments.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.segments];

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search this analysis view";
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:.08];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.segments.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:8],
        [self.segments.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-8],
        [self.segments.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.segments.bottomAnchor constant:8],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    [self rebuildRows];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)selectionChanged:(NSNotification *)note {
    if (note.object == self) return;
    NSNumber *address = note.userInfo[UCAnalysisSelectionAddressKey];
    if (!address || !self.tableView) return;
    if (![self.mode isEqualToString:@"Memory"] && ![self.mode isEqualToString:@"Flow"] && ![self.mode isEqualToString:@"Strings"]) return;
    [self rebuildRows];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSArray *names = @[@"Overview", @"Strings", @"Symbols", @"Functions", @"Graph", @"Flow", @"Memory", @"Patch", @"Diff"];
    self.mode = names[sender.selectedSegmentIndex];
    [self rebuildRows];
}

- (void)rebuildRows {
    NSMutableArray *r = [NSMutableArray array];
    if ([self.mode isEqualToString:@"Overview"]) {
        [r addObject:@{ @"title": self.function.name ?: @"Unnamed function", @"detail": [NSString stringWithFormat:@"0x%llx → 0x%llx", self.function.startAddress, self.function.endAddress], @"kind": @"header" }];
        [r addObject:@{ @"title": @"Instructions", @"detail": [NSString stringWithFormat:@"%lu", (unsigned long)self.function.instructions.count] }];
        [r addObject:@{ @"title": @"Basic blocks", @"detail": [NSString stringWithFormat:@"%lu", (unsigned long)self.function.basicBlocks.count] }];
        NSUInteger calls=0, xrefs=0, strings=0;
        for (UCDisasmInstruction *i in self.function.instructions) { calls += i.isCall; xrefs += i.xrefFrom.count; strings += ([i.comment containsString:@"string"] || [i.comment containsString:@"String"]); }
        [r addObject:@{ @"title": @"Calls / XREFs", @"detail": [NSString stringWithFormat:@"%lu calls · %lu inbound XREFs", (unsigned long)calls, (unsigned long)xrefs] }];
        [r addObject:@{ @"title": @"Local bytes", @"detail": [NSString stringWithFormat:@"%lu decoded bytes", (unsigned long)self.patchBytes.length] }];
        [r addObject:@{ @"title": @"Architecture", @"detail": @"ARM64 · Capstone · on-device" }];
        [r addObject:@{ @"title": @"Analysis model", @"detail": @"Annotated UCFunction shared by Disassembler / CFG / Pseudocode" }];
    } else if ([self.mode isEqualToString:@"Strings"]) {
        for (UCDisasmInstruction *i in self.function.instructions) {
            NSString *c = i.comment ?: @"";
            if (c.length && ([c containsString:@"string"] || [c containsString:@"String"] || [c containsString:@"\""])) {
                [r addObject:@{ @"title": c, @"detail": [NSString stringWithFormat:@"0x%llx  ·  %@", i.address, i.fullText ?: @""], @"address": @(i.address) }];
            }
        }
        if (!r.count) [r addObject:@{ @"title": @"No string annotations in this function", @"detail": @"Load another function or use the local scanner's string browser." }];
    } else if ([self.mode isEqualToString:@"Symbols"]) {
        NSMutableSet *seen = [NSMutableSet set];
        if (self.function.name.length) { [r addObject:@{ @"title": self.function.name, @"detail": [NSString stringWithFormat:@"function @ 0x%llx", self.function.startAddress] }]; [seen addObject:self.function.name]; }
        for (UCDisasmInstruction *i in self.function.instructions) {
            NSString *s = i.functionName.length ? i.functionName : i.comment;
            if (s.length && ![seen containsObject:s]) { [seen addObject:s]; [r addObject:@{ @"title": s, @"detail": [NSString stringWithFormat:@"0x%llx · %@", i.address, i.fullText ?: @""] }]; }
        }
        if (!r.count) [r addObject:@{ @"title": @"No resolved symbols", @"detail": @"The annotation layer did not resolve a symbol in this function." }];
    } else if ([self.mode isEqualToString:@"Functions"]) {
        [r addObject:@{ @"title": self.function.name ?: @"Current function", @"detail": [NSString stringWithFormat:@"0x%llx · %lu %@ · %lu blocks · %lu instructions", self.function.startAddress, (unsigned long)self.function.size, self.function.boundaryIsBounded ? @"bytes (bounded)" : @"bytes", (unsigned long)self.function.basicBlocks.count, (unsigned long)self.function.instructions.count], @"action": @"function" }];
        for (UCDisasmInstruction *i in self.function.instructions) if (i.isCall) [r addObject:@{ @"title": i.comment.length ? i.comment : [NSString stringWithFormat:@"call 0x%llx", i.branchTarget], @"detail": [NSString stringWithFormat:@"caller 0x%llx", i.address], @"action": @"call" }];
    } else if ([self.mode isEqualToString:@"Graph"]) {
        for (UCBasicBlock *b in self.function.basicBlocks) {
            NSMutableString *detail = [NSMutableString stringWithFormat:@"loc_%llx · %lu instructions", b.startAddress, (unsigned long)b.instructions.count];
            if (b.successors.count) { [detail appendString:@" · → "]; for (UCBasicBlock *s in b.successors) [detail appendFormat:@"loc_%llx ", s.startAddress]; }
            [r addObject:@{ @"title": [NSString stringWithFormat:@"Block %ld", (long)b.blockId], @"detail": detail }];
        }
    } else if ([self.mode isEqualToString:@"Flow"]) {
        for (UCDisasmInstruction *i in self.function.instructions) {
            if (i.isCall || i.isBranch || i.xrefFrom.count) {
                NSString *kind = i.isCall ? @"CALL" : (i.isBranch ? @"BRANCH" : @"XREF");
                [r addObject:@{ @"title": [NSString stringWithFormat:@"%@ 0x%llx", kind, i.address], @"detail": [NSString stringWithFormat:@"%@%@", i.fullText ?: @"", i.comment.length ? [NSString stringWithFormat:@" · %@", i.comment] : @""], @"address": @(i.address) }];
            }
        }
        if (!r.count) [r addObject:@{ @"title": @"No control/data-flow edges found", @"detail": @"Try a larger function window." }];
    } else if ([self.mode isEqualToString:@"Memory"]) {
        const uint8_t *bytes = self.patchBytes.bytes;
        for (NSUInteger off=0; off<self.patchBytes.length; off+=16) {
            NSMutableString *hex=[NSMutableString string]; NSMutableString *ascii=[NSMutableString string];
            NSUInteger n=MIN(16,self.patchBytes.length-off);
            for (NSUInteger j=0;j<n;j++) { uint8_t b=bytes[off+j]; [hex appendFormat:@"%02x ",b]; [ascii appendFormat:@"%c", (b>=32&&b<127)?b:'.']; }
            [r addObject:@{ @"title": [NSString stringWithFormat:@"0x%llx", self.function.startAddress+off], @"detail": [NSString stringWithFormat:@"%-48s  %@", hex.UTF8String, ascii] }];
        }
    } else if ([self.mode isEqualToString:@"Patch"]) {
        [r addObject:@{ @"title": @"NOP selected instruction", @"detail": @"Select an instruction to create a local patch proposal (D503201F).", @"action": @"nop" }];
        [r addObject:@{ @"title": @"RET selected instruction", @"detail": @"Select an instruction to create a local patch proposal (D65F03C0).", @"action": @"ret" }];
        [r addObject:@{ @"title": @"Export patch manifest", @"detail": @"Copies a local, reversible patch manifest to the clipboard.", @"action": @"export" }];
        for (NSDictionary *p in self.patches) [r addObject:@{ @"title": p[@"label"] ?: @"Patch", @"detail": [NSString stringWithFormat:@"%@ → %@", p[@"old"] ?: @"", p[@"new"] ?: @""] }];
    } else if ([self.mode isEqualToString:@"Diff"]) {
        [r addObject:@{ @"title": @"Original vs local patch workspace", @"detail": [NSString stringWithFormat:@"%lu proposed changes · no source binary modified", (unsigned long)self.patches.count] }];
        for (NSDictionary *p in self.patches) [r addObject:@{ @"title": p[@"label"] ?: @"change", @"detail": [NSString stringWithFormat:@"OLD %@    NEW %@", p[@"old"] ?: @"", p[@"new"] ?: @""] }];
        if (!self.patches.count) [r addObject:@{ @"title": @"No differences yet", @"detail": @"Create a patch proposal from the Patch tab." }];
    }
    self.allRows = r;
    self.rows = r;
    if (self.tableView) [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = searchController.searchBar.text.lowercaseString ?: @"";
    if (!q.length) self.rows = self.allRows;
    else {
        NSMutableArray *m=[NSMutableArray array];
        for (NSDictionary *row in self.allRows) { NSString *h=[NSString stringWithFormat:@"%@ %@",row[@"title"]?:@"",row[@"detail"]?:@""]; if ([h.lowercaseString containsString:q]) [m addObject:row]; }
        self.rows=m;
    }
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c=[tv dequeueReusableCellWithIdentifier:@"analysis"];
    if(!c) c=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"analysis"];
    NSDictionary *r=self.rows[ip.row]; c.backgroundColor=UIColor.blackColor; c.textLabel.textColor=UIColor.whiteColor; c.detailTextLabel.textColor=[UIColor colorWithWhite:.62 alpha:1]; c.textLabel.font=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium]; c.detailTextLabel.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]; c.textLabel.text=r[@"title"]; c.detailTextLabel.text=r[@"detail"]; c.detailTextLabel.numberOfLines=0; c.accessoryType=r[@"action"]?UITableViewCellAccessoryDisclosureIndicator:UITableViewCellAccessoryNone; return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES]; NSDictionary *r=self.rows[ip.row]; NSString *action=r[@"action"];
    if ([action isEqualToString:@"function"]) { [[UCAnalysisSelection shared] selectAddress:self.function.startAddress functionAddress:self.function.startAddress kind:@"function"]; [self openCFG]; return; }
    if ([action isEqualToString:@"call"]) { UIPasteboard.generalPasteboard.string=r[@"title"]; return; }
    if ([action isEqualToString:@"export"]) { [self exportPatches]; return; }
    if ([action isEqualToString:@"nop"] || [action isEqualToString:@"ret"]) { [self chooseInstructionPatch:action]; return; }
    NSNumber *address=r[@"address"]; if (address) {
        [[UCAnalysisSelection shared] selectAddress:address.unsignedLongLongValue functionAddress:self.function.startAddress kind:self.mode.lowercaseString];
    }
    if (address && [self.mode isEqualToString:@"Flow"]) {
        UCDisasmInstruction *target=nil; for(UCDisasmInstruction *i in self.function.instructions) if(i.address==address.unsignedLongLongValue){target=i;break;}
        if(target.xrefFrom.count){ UCXrefListViewController *vc=[[UCXrefListViewController alloc] initWithTargetAddress:target.address sourceAddresses:target.xrefFrom]; [self.navigationController pushViewController:vc animated:YES]; }
    }
}

- (void)chooseInstructionPatch:(NSString *)kind {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:[kind isEqualToString:@"nop"]?@"NOP patch":@"RET patch" message:@"Choose an instruction from the local function." preferredStyle:UIAlertControllerStyleActionSheet];
    for(UCDisasmInstruction *i in self.function.instructions) {
        if(i.size!=4) continue;
        NSString *title=[NSString stringWithFormat:@"0x%llx  %@",i.address,i.fullText?:@""];
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){
            NSString *old=i.bytesHex?:@""; NSString *nw=[kind isEqualToString:@"nop"]?@"1F 20 03 D5":@"C0 03 5F D6";
            [self.patches addObject:@{ @"label":[NSString stringWithFormat:@"%@ @ 0x%llx",[kind uppercaseString],i.address], @"address":@(i.address), @"old":old, @"new":nw }];
            [self rebuildRows];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if(UI_USER_INTERFACE_IDIOM()==UIUserInterfaceIdiomPad){a.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;}
    [self presentViewController:a animated:YES completion:nil];
}

- (void)exportPatches {
    NSMutableString *s=[NSMutableString stringWithString:@"AirShare local patch manifest\n"];
    for(NSDictionary *p in self.patches) [s appendFormat:@"%@ | OLD %@ | NEW %@\n",p[@"label"],p[@"old"],p[@"new"]];
    UIPasteboard.generalPasteboard.string=s;
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Copied" message:@"The local patch manifest is on the clipboard. The source binary was not modified by this viewer." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]]; [self presentViewController:a animated:YES completion:nil];
}

- (void)openCFG { UCDisasmViewController *vc=[[UCDisasmViewController alloc] initWithFunction:self.function title:self.function.name]; [self.navigationController pushViewController:vc animated:YES]; }

- (void)navigate {
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Navigate" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Disassembler" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ UCDisasmViewController *v=[[UCDisasmViewController alloc] initWithFunction:self.function title:self.function.name]; [self.navigationController pushViewController:v animated:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"CFG Viewer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self openCFG]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Pseudocode" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ NSString *t=[UCPseudocodeViewController pseudocodeForFunction:self.function]; UCPseudocodeViewController *v=[[UCPseudocodeViewController alloc] initWithPseudocode:t title:@"Pseudocode"]; [self.navigationController pushViewController:v animated:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Strings Browser" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self.navigationController pushViewController:[[UCStringsBrowserViewController alloc] initWithFunction:self.function] animated:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Function Explorer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){ [self.navigationController pushViewController:[[UCFunctionExplorerViewController alloc] initWithFunctions:@[self.function]] animated:YES]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if(UI_USER_INTERFACE_IDIOM()==UIUserInterfaceIdiomPad) a.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;
    [self presentViewController:a animated:YES completion:nil];
}
@end
