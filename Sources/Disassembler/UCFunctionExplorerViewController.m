#import "UCFunctionExplorerViewController.h"
#import "UCAnalysisSelection.h"
#import "UCDisasmViewController.h"

@interface UCFunctionExplorerViewController ()
@property(nonatomic,strong) NSArray<UCFunction *> *functions;
@property(nonatomic,strong) NSArray<UCFunction *> *rows;
@property(nonatomic,strong) UISearchController *search;
@end
@implementation UCFunctionExplorerViewController
- (instancetype)initWithFunctions:(NSArray<UCFunction *> *)functions { self=[super initWithStyle:UITableViewStylePlain]; if(self){_functions=functions;_rows=functions;self.title=@"Functions";} return self; }
- (void)viewDidLoad { [super viewDidLoad]; self.tableView.backgroundColor=UIColor.blackColor; self.search=[[UISearchController alloc] initWithSearchResultsController:nil]; self.search.obscuresBackgroundDuringPresentation=NO; self.search.searchResultsUpdater=self; self.navigationItem.searchController=self.search; [self.tableView reloadData]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)sc { NSString *q=sc.searchBar.text.lowercaseString?:@""; self.rows=q.length?[self.functions filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(UCFunction *f, NSDictionary *_) { return [f.name.lowercaseString containsString:q]
    || [[NSString stringWithFormat:@"%llx", f.startAddress] containsString:q]; }]]:self.functions; [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section{return self.rows.count;}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip { UITableViewCell *c=[tv dequeueReusableCellWithIdentifier:@"function"]?:[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"function"]; UCFunction *f=self.rows[ip.row]; c.backgroundColor=UIColor.blackColor;c.textLabel.textColor=UIColor.whiteColor;c.detailTextLabel.textColor=[UIColor colorWithWhite:.62 alpha:1];c.textLabel.font=[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];c.detailTextLabel.font=[UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];c.textLabel.text=f.name;c.detailTextLabel.text=[NSString stringWithFormat:@"0x%llx · %lu bytes · %lu blocks · %lu instructions",f.startAddress,(unsigned long)f.size,(unsigned long)f.basicBlocks.count,(unsigned long)f.instructions.count];c.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return c; }
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip { [tv deselectRowAtIndexPath:ip animated:YES]; UCFunction *f=self.rows[ip.row]; [[UCAnalysisSelection shared] selectAddress:f.startAddress functionAddress:f.startAddress kind:@"function"]; [self.navigationController pushViewController:[[UCDisasmViewController alloc]initWithFunction:f title:f.name] animated:YES]; }
@end
