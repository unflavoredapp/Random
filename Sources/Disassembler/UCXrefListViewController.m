#import "UCXrefListViewController.h"
#import "UCDisassembler.h"
#import "UCDisasmViewController.h"
#import "AVX512Color.h"

NS_ASSUME_NONNULL_BEGIN

@interface UCXrefEntry : NSObject
@property (nonatomic, assign) uint64_t address;
@property (nonatomic, copy, nullable) NSString *resolvedName;
@end

@implementation UCXrefEntry
@end

@interface UCXrefListViewController () <UITableViewDataSource, UITableViewDelegate>

@property (nonatomic, assign) uint64_t targetAddress;
@property (nonatomic, strong) NSArray<UCXrefEntry *> *entries;
@property (nonatomic, strong) UITableView *tableView;

@end

@implementation UCXrefListViewController

- (instancetype)initWithTargetAddress:(uint64_t)targetAddress
                       sourceAddresses:(NSArray<NSNumber *> *)sourceAddresses {
    self = [super init];
    if (self) {
        _targetAddress = targetAddress;

        NSMutableArray<UCXrefEntry *> *entries = [NSMutableArray array];
        for (NSNumber *addrNum in sourceAddresses) {
            uint64_t addr = addrNum.unsignedLongLongValue;
            UCXrefEntry *entry = [UCXrefEntry new];
            entry.address = addr;
            entry.resolvedName = [UCDisassembler symbolNameAtAddress:addr]
                ?: [UCDisassembler objcMethodNameAtAddress:addr];
            [entries addObject:entry];
        }
        [entries sortUsingComparator:^NSComparisonResult(UCXrefEntry *a, UCXrefEntry *b) {
            return a.address < b.address ? NSOrderedAscending
                 : a.address > b.address ? NSOrderedDescending
                 : NSOrderedSame;
        }];
        _entries = entries;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = AVX512Color.primaryBackgroundColor;
    self.title = [NSString stringWithFormat:@"XREFs to 0x%llx (%lu)",
                  self.targetAddress, (unsigned long)self.entries.count];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self
        action:@selector(doneAction)];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"XrefCell"];

    [self.view addSubview:self.tableView];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.tableView.frame = self.view.bounds;
}

- (void)doneAction {
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.entries.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"XrefCell" forIndexPath:indexPath];
    UCXrefEntry *entry = self.entries[indexPath.row];

    cell.textLabel.text = [NSString stringWithFormat:@"0x%llx", entry.address];
    cell.textLabel.font = [UIFont fontWithName:@"Menlo-Regular" size:13];
    cell.detailTextLabel.text = entry.resolvedName ?: @"(unresolved caller)";
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];
    cell.detailTextLabel.textColor = entry.resolvedName ? [UIColor darkGrayColor] : [UIColor lightGrayColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    UCXrefEntry *entry = self.entries[indexPath.row];

    NSString *title = entry.resolvedName ?: [NSString stringWithFormat:@"0x%llx", entry.address];
    UCDisasmViewController *disasmVC = [[UCDisasmViewController alloc]
        initWithAddress:entry.address size:(64 * 1024) title:title];

    __weak UIViewController *presenter = self.presentingViewController;
    [self dismissViewControllerAnimated:YES completion:^{
        __strong UIViewController *strongPresenter = presenter;
        if (!strongPresenter) return;
        if (strongPresenter.navigationController) {
            [strongPresenter.navigationController pushViewController:disasmVC animated:YES];
        } else {
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:disasmVC];
            [strongPresenter presentViewController:nav animated:YES completion:nil];
        }
    }];
}

@end

NS_ASSUME_NONNULL_END
