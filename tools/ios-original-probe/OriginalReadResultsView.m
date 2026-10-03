#ifndef CAMPUS_ORIGINAL_PROBE_TEST
#import <UIKit/UIKit.h>
#import "OriginalNetworkProbe.h"

@interface CampusOriginalReadResultsController : UITableViewController
@property(nonatomic, copy) NSArray *rows;
@property(nonatomic, copy) void (^clearResult)(void);
@end
@implementation CampusOriginalReadResultsController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"本次洗衣只读结果";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 100;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"返回诊断" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"清除结果" style:UIBarButtonItemStylePlain target:self action:@selector(clear)];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)clear { self.rows = @[]; if (self.clearResult) self.clearResult(); [self.tableView reloadData]; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.rows.count + 1; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    NSDictionary *row = indexPath.row ? self.rows[indexPath.row - 1] : @{@"title": @"本次查询快照", @"detail": @"只读查看本人订单与设备。记录保留在当前页面内存，诊断报告不包含这些内容。价格为服务器标示价，实际应付尚未核验。此页不会下单、付款或启动机器。"};
    cell.textLabel.text = row[@"title"]; cell.detailTextLabel.text = row[@"detail"];
    return cell;
}
@end

void CampusOriginalPresentReadResults(UIViewController *parent, NSArray *rows, void (^clear)(void)) {
    CampusOriginalReadResultsController *controller = [[CampusOriginalReadResultsController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    controller.rows = [rows copy]; controller.clearResult = clear;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [parent presentViewController:navigation animated:YES completion:nil];
}
#endif
