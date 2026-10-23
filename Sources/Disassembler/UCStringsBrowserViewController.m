#import "UCStringsBrowserViewController.h"
#import "UCAnalysisSelection.h"
#import "UCDisasmViewController.h"
#import "UCXrefListViewController.h"

@interface UCStringsBrowserViewController ()
@property(nonatomic,strong) UCFunction *function;
@property(nonatomic,strong) NSArray<NSDictionary *> *allRows;
@property(nonatomic,strong) NSArray<NSDictionary *> *rows;
@property(nonatomic,strong) UISearchController *search;
@end

@implementation UCStringsBrowserViewController
- (instancetype)initWithFunction:(UCFunction *)function {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self) { _function = function; self.title = @"Strings"; }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorColor = [UIColor colorWithWhite:.16 alpha:1];
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchResultsUpdater = self;
    self.navigationItem.searchController = self.search;
    [self rebuild];
}
- (void)rebuild {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *unique = [NSMutableDictionary dictionary];
    for (UCDisasmInstruction *i in self.function.instructions) {
        NSString *candidate = i.comment.length ? i.comment : nil;
        if (!candidate.length) continue;
        // Keep only likely string/selector references, not generic control-flow labels.
        BOOL likely = [candidate rangeOfString:@"string" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [candidate rangeOfString:@"\""].location != NSNotFound ||
                      [candidate rangeOfString:@"NSString" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                      [candidate rangeOfString:@"selector" options:NSCaseInsensitiveSearch].location != NSNotFound;
        if (!likely) continue;
        NSString *key = candidate.lowercaseString;
        NSMutableDictionary *row = unique[key];
        if (!row) {
            row = [@{ @"text": candidate,
                      @"address": @(i.address),
                      @"refs": [NSMutableArray array] } mutableCopy];
            unique[key] = row;
        }
        [row[ @"refs"] addObject:@(i.address)];
    }
    NSMutableArray *r = [NSMutableArray array];
    for (NSDictionary *v in unique.allValues) {
        NSArray *refs = v[@"refs"];
        [r addObject:@{ @"text":v[@"text"], @"address":v[@"address"], @"refs":refs, @"detail":[NSString stringWithFormat:@"0x%llx · %lu reference%@", [v[@"address"] unsignedLongLongValue], (unsigned long)refs.count, refs.count == 1 ? @"" : @"s"] }];
    }
    [r sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"address"] compare:b[@"address"]]; }];
    self.allRows = r; self.rows = r; [self.tableView reloadData];
}
- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text.lowercaseString ?: @"";
    if (!q.length) self.rows = self.allRows;
    else self.rows = [self.allRows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *r, NSDictionary *_) { return [[r[@"text"] lowercaseString] containsString:q] || [[r[@"detail"] lowercaseString] containsString:q]; }]];
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section { return self.rows.count; }
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"string"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"string"];
    NSDictionary *r = self.rows[ip.row]; c.backgroundColor=UIColor.blackColor; c.textLabel.textColor=UIColor.whiteColor; c.detailTextLabel.textColor=[UIColor colorWithWhite:.62 alpha:1]; c.textLabel.font=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium]; c.detailTextLabel.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular]; c.textLabel.text=r[@"text"]; c.detailTextLabel.text=r[@"detail"]; c.accessoryType=UITableViewCellAccessoryDisclosureIndicator; return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES]; NSDictionary *r=self.rows[ip.row]; uint64_t a=[r[@"address"] unsignedLongLongValue];
    [[UCAnalysisSelection shared] selectAddress:a functionAddress:self.function.startAddress kind:@"string"];
    NSArray *refs=r[@"refs"];
    UCXrefListViewController *x=[[UCXrefListViewController alloc] initWithTargetAddress:a sourceAddresses:refs];
    [self.navigationController pushViewController:x animated:YES];
}
@end
