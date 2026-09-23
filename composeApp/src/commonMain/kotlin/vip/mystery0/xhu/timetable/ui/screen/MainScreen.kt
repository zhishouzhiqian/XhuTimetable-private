package vip.mystery0.xhu.timetable.ui.screen

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.clickable
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.FlexibleBottomAppBar
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Switch
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.twotone.LocalLaundryService
import androidx.compose.material.icons.twotone.QrCodeScanner
import androidx.compose.ui.util.lerp
import co.touchlab.kermit.Logger
import coil3.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import org.jetbrains.compose.resources.DrawableResource
import org.koin.compose.viewmodel.koinViewModel
import vip.mystery0.xhu.timetable.base.HandleErrorMessage
import vip.mystery0.xhu.timetable.config.coroutine.safeLaunch
import vip.mystery0.xhu.timetable.config.store.EventBus
import vip.mystery0.xhu.timetable.config.trackEvent
import vip.mystery0.xhu.timetable.model.event.EventType
import vip.mystery0.xhu.timetable.ui.component.ShowUpdateDialog
import vip.mystery0.xhu.timetable.ui.component.Tab
import vip.mystery0.xhu.timetable.ui.component.loadCoilModelWithoutCache
import vip.mystery0.xhu.timetable.ui.component.loading.LoadingButton
import vip.mystery0.xhu.timetable.ui.component.loading.LoadingValue
import vip.mystery0.xhu.timetable.ui.component.tabOfWhenDisableCalendar
import vip.mystery0.xhu.timetable.ui.component.tabOfWhenEnableCalendar
import vip.mystery0.xhu.timetable.ui.navigation.LocalNavController
import vip.mystery0.xhu.timetable.ui.navigation.RouteLogin
import vip.mystery0.xhu.timetable.ui.navigation.RouteMain
import vip.mystery0.xhu.timetable.ui.navigation.RouteWater
import vip.mystery0.xhu.timetable.ui.navigation.RouteLaundry
import vip.mystery0.xhu.timetable.ui.theme.XhuIcons
import vip.mystery0.xhu.timetable.model.water.WaterUiState
import vip.mystery0.xhu.timetable.model.water.WaterStartDecision
import vip.mystery0.xhu.timetable.model.water.formatWaterCents
import vip.mystery0.xhu.timetable.model.water.WaterQuickAction
import vip.mystery0.xhu.timetable.model.water.decideWaterQuickAction
import vip.mystery0.xhu.timetable.ui.navigation.replaceTo
import vip.mystery0.xhu.timetable.ui.theme.isDarkMode
import vip.mystery0.xhu.timetable.ui.theme.stateOf
import vip.mystery0.xhu.timetable.viewmodel.MainViewModel
import vip.mystery0.xhu.timetable.viewmodel.PagerProfileViewModel
import vip.mystery0.xhu.timetable.viewmodel.WaterViewModel
import vip.mystery0.xhu.timetable.viewmodel.LaundryViewModel
import vip.mystery0.xhu.timetable.model.laundry.LaundryPhase
import vip.mystery0.xhu.timetable.model.laundry.selectHomepageLaundryOrder
import kotlin.time.Clock

@Composable
fun MainScreen() {
    val viewModel = koinViewModel<MainViewModel>()
    val waterViewModel = koinViewModel<WaterViewModel>()
    val laundryViewModel = koinViewModel<LaundryViewModel>()

    val navController = LocalNavController.current

    val isDarkMode = isDarkMode()

    val enableCalendarView by viewModel.enableCalendarView.collectAsState()
    val backgroundImage by viewModel.backgroundImage.collectAsState()
    val backgroundImageBlur by viewModel.backgroundImageBlur.collectAsState()

    val coroutineScope = rememberCoroutineScope()
    val pagerState = rememberPagerState(initialPage = 0) { if (enableCalendarView) 4 else 3 }

    LaunchedEffect(Unit) {
        viewModel.loadBackground(isDarkMode)
        waterViewModel.init()
        if (isLaundryServiceSupported) laundryViewModel.init()
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, isLaundryServiceSupported) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && isLaundryServiceSupported &&
                laundryViewModel.uiState.value.phase !in setOf(
                    LaundryPhase.CheckingSession,
                    LaundryPhase.LoggingIn,
                )
            ) {
                laundryViewModel.controller.checkSession()
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    HandleEventBus()
    ShowUpdateDialog()
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior()
    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            val tab = if (enableCalendarView) {
                tabOfWhenEnableCalendar(pagerState.currentPage)
            } else {
                tabOfWhenDisableCalendar(pagerState.currentPage)
            }
            CenterAlignedTopAppBar(
                scrollBehavior = scrollBehavior,
                title = {
                    tab.titleBar?.let { it() }
                },
                navigationIcon = {
                    if (tab == Tab.TODAY) {
                        Row(verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                            WaterQuickControl(waterViewModel) {
                                navController.navigate(RouteWater)
                            }
                            if (isLaundryServiceSupported) {
                                LaundryQuickControl(laundryViewModel) {
                                    navController.navigate(RouteLaundry)
                                }
                            }
                        }
                    }
                },
                actions = {
                    val loading by viewModel.loading.collectAsState()
                    val actions = tab.actions
                    val loadingValue = if (loading) LoadingValue.Loading else LoadingValue.Stop
                    if (actions != null) {
                        if (actions(this)) {
                            LoadingButton(
                                loadingValue = loadingValue,
                                modifier = Modifier
                                    .fillMaxHeight()
                            ) {
                                trackEvent("手动刷新课表")
                                viewModel.refreshCloudDataToState()
                            }
                        }
                    } else {
                        LoadingButton(
                            loadingValue = loadingValue,
                            modifier = Modifier
                                .fillMaxHeight()
                        ) {
                            trackEvent("手动刷新课表")
                            viewModel.refreshCloudDataToState()
                        }
                    }
                }
            )
        },
        bottomBar = {
            val showTomorrowCourse by viewModel.showTomorrowCourse.collectAsState()
            FlexibleBottomAppBar {
                val tabs = if (enableCalendarView) {
                    Tab.entries
                } else {
                    Tab.entries.filter { it != Tab.CALENDAR }
                }
                tabs.forEachIndexed { index, tab ->
                    DrawNavigationItem(
                        checked = pagerState.currentPage == index,
                        showTomorrowCourse = showTomorrowCourse,
                        tab = tab,
                        icon = tab.icon,
                    ) {
                        coroutineScope.safeLaunch(Dispatchers.Main) {
                            pagerState.animateScrollToPage(index)
                        }
                    }
                }
            }
        }
    ) { paddingValues ->
        Box {
            if (backgroundImage != Unit) {
                AsyncImage(
                    model = loadCoilModelWithoutCache(backgroundImage),
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxSize()
                        .blur(backgroundImageBlur.dp)
                )
            }
            HorizontalPager(
                beyondViewportPageCount = 3,
                state = pagerState,
                modifier = Modifier.padding(paddingValues),
            ) { page ->
                Column(
                    modifier = Modifier
                        .graphicsLayer {
                            val pageOffset =
                                (pagerState.currentPage - page + pagerState.currentPageOffsetFraction)
                            lerp(0.85f, 1f, 1f - pageOffset.coerceIn(0f, 1f))
                                .also { scale ->
                                    scaleX = scale
                                    scaleY = scale
                                }
                            alpha = lerp(0.5f, 1f, 1f - pageOffset.coerceIn(0f, 1f))
                        }
                        .fillMaxSize()
                ) {
                    val tab = if (enableCalendarView) {
                        tabOfWhenEnableCalendar(page)
                    } else {
                        tabOfWhenDisableCalendar(page)
                    }
                    tab.content(this)
                }
            }
        }
    }

    HandleErrorMessage(flow = viewModel.errorMessage)
    HandleErrorMessage(flow = waterViewModel.errorMessage)
    val waterState by waterViewModel.uiState.collectAsState()
    val authenticationRequest by waterViewModel.authenticationRequest.collectAsState()
    if (waterState == WaterUiState.RecoveringAuthentication) {
        authenticationRequest?.let { request ->
            WaterAuthenticationView(
                modifier = Modifier.size(1.dp).alpha(0F),
                request = request,
                onAuthenticated = waterViewModel::completeAuthentication,
                onError = { waterViewModel.failAuthenticationRecovery() },
            )
        }
    }
    if (isLaundryServiceSupported) {
        LaundryWebSessionView(
            modifier = Modifier.size(1.dp).alpha(0F),
            controller = laundryViewModel.controller,
            loginMode = false,
            foreground = false,
        )
    }
    val emptyUser by viewModel.emptyUser.collectAsState()
    if (emptyUser) {
        navController.replaceTo<RouteMain>(RouteLogin(false))
    }

    val startConfirmation by waterViewModel.startConfirmation.collectAsState()
    startConfirmation?.let { confirmation ->
        AlertDialog(
            onDismissRequest = waterViewModel::dismissStartConfirmation,
            title = {
                Text(
                    if (confirmation is WaterStartDecision.LowBalance) "校园卡余额较低"
                    else "无法读取校园卡余额",
                )
            },
            text = {
                Text(
                    when (confirmation) {
                        is WaterStartDecision.LowBalance ->
                            "当前余额 ¥${formatWaterCents(confirmation.balanceCents)}，低于 ¥2.00。仍要开水吗？"
                        WaterStartDecision.BalanceUnavailable ->
                            "暂时无法读取余额，请确认校园卡余额充足后再继续。"
                        is WaterStartDecision.Ready -> "确认开水吗？"
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = waterViewModel::confirmStart) { Text("确认开水") }
            },
            dismissButton = {
                TextButton(onClick = waterViewModel::dismissStartConfirmation) { Text("取消") }
            },
        )
    }
}

@Composable
private fun LaundryQuickControl(viewModel: LaundryViewModel, openDetails: () -> Unit) {
    val state by viewModel.uiState.collectAsState()
    val active = selectHomepageLaundryOrder(state.orders)
    var now by remember { mutableLongStateOf(Clock.System.now().toEpochMilliseconds()) }
    LaunchedEffect(active?.expectedEndAtEpochMillis) {
        while (active?.expectedEndAtEpochMillis != null) {
            now = Clock.System.now().toEpochMilliseconds()
            delay(1_000)
        }
    }
    val remainingMinutes = active?.expectedEndAtEpochMillis?.minus(now)
        ?.coerceAtLeast(0)?.div(60_000)
    val busy = state.phase == LaundryPhase.CheckingSession ||
        state.phase == LaundryPhase.CheckingOrders
    IconButton(
        onClick = {
            if (state.phase == LaundryPhase.Idle) viewModel.beginScan()
            openDetails()
        },
    ) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
        } else {
            Column(horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) {
                Icon(
                    imageVector = if (active == null) Icons.TwoTone.QrCodeScanner
                    else Icons.TwoTone.LocalLaundryService,
                    contentDescription = if (active == null) "扫描洗衣机" else "查看洗衣剩余时间",
                    tint = if (active == null) MaterialTheme.colorScheme.onSurface
                    else MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(if (active == null) 24.dp else 20.dp),
                )
                if (remainingMinutes != null) {
                    Text("${remainingMinutes}分", fontSize = 10.sp, lineHeight = 10.sp)
                }
            }
        }
    }
}

@Composable
private fun WaterQuickControl(viewModel: WaterViewModel, openDetails: () -> Unit) {
    val state by viewModel.uiState.collectAsState()
    val credentials by viewModel.credentials.collectAsState()
    val running by viewModel.lastKnownRunning.collectAsState()
    val actionInProgress by viewModel.actionInProgress.collectAsState()
    val busy = actionInProgress || state == WaterUiState.Starting || state == WaterUiState.Stopping
    val action = decideWaterQuickAction(credentials, state, running)
    Box(
        modifier = Modifier
            .clickable(enabled = !busy) {
                when (action) {
                    WaterQuickAction.NavigateToDetails -> openDetails()
                    WaterQuickAction.Start, WaterQuickAction.Stop -> viewModel.toggleWater()
                    WaterQuickAction.Wait -> {
                        if (state == WaterUiState.Authenticating) openDetails()
                        else viewModel.toggleWater()
                    }
                }
            }
            .padding(horizontal = 8.dp),
    ) {
        if (busy) {
            CircularProgressIndicator(modifier = Modifier.size(28.dp), strokeWidth = 2.dp)
        } else {
            Switch(
                checked = running,
                onCheckedChange = null,
                thumbContent = {
                    Icon(
                        painter = XhuIcons.Action.switch,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                    )
                },
            )
        }
    }
}

@Composable
private fun RowScope.DrawNavigationItem(
    checked: Boolean,
    showTomorrowCourse: Boolean,
    tab: Tab,
    icon: Pair<Pair<DrawableResource, DrawableResource>, Pair<DrawableResource, DrawableResource>>,
    onSelect: () -> Unit = {},
) {
    val label = if (showTomorrowCourse) tab.otherLabel else tab.label

    NavigationBarItem(
        modifier = Modifier.weight(1F),
        selected = checked,
        icon = {
            Icon(
                painter = stateOf(checked = checked, pair = icon),
                tint = Color.Unspecified,
                modifier = Modifier.size(24.dp),
                contentDescription = null,
            )
        },
        label = {
            Text(text = label)
        },
        onClick = {
            onSelect()
        },
        colors = NavigationBarItemDefaults.colors(
            selectedIconColor = MaterialTheme.colorScheme.primary,
            selectedTextColor = MaterialTheme.colorScheme.primary,
        )
    )
}

@Composable
private fun HandleEventBus() {
    val viewModel = koinViewModel<MainViewModel>()
    val profileViewModel = koinViewModel<PagerProfileViewModel>()

    LaunchedEffect(Unit) {
        EventBus.flow.collect { event ->
            event.getContentIfNotHandled()?.let { eventType ->
                Logger.i("eventbus: $eventType")
                viewModel.loadConfig()
                when (eventType) {
                    EventType.MULTI_MODE_CHANGED,
                    EventType.CHANGE_ENABLE_CALENDAR_VIEW,
                    EventType.CHANGE_MAIN_USER -> {
                        viewModel.checkMainUser()
                        viewModel.refreshCloudDataToState()
                    }

                    EventType.CHANGE_CURRENT_YEAR_AND_TERM,
                    EventType.CHANGE_SHOW_CUSTOM_COURSE,
                    EventType.CHANGE_SHOW_CUSTOM_THING,
                    EventType.CHANGE_CAMPUS -> {
                        viewModel.refreshCloudDataToState()
                    }

                    EventType.MAIN_USER_LOGOUT -> {
                        viewModel.checkMainUser()
                    }

                    EventType.CHANGE_TERM_START_TIME,
                    EventType.CHANGE_AUTO_SHOW_TOMORROW_COURSE -> {
                        viewModel.loadLocalDataToState(changeWeekOnly = true)
                        viewModel.calculateTodayTitle()
                        viewModel.loadTodayHoliday()
                    }

                    EventType.CHANGE_SHOW_HOLIDAY -> {
                        viewModel.loadTodayHoliday()
                    }

                    EventType.CHANGE_SHOW_STATUS,
                    EventType.CHANGE_SHOW_NOT_THIS_WEEK,
                    EventType.CHANGE_COURSE_COLOR,
                    EventType.CHANGE_CUSTOM_UI,
                    EventType.CHANGE_CUSTOM_ACCOUNT_TITLE -> {
                        viewModel.loadLocalDataToState(changeWeekOnly = true)
                    }

                    EventType.CHANGE_MAIN_BACKGROUND -> {
                        viewModel.loadBackground()
                    }

                    EventType.UPDATE_NOTICE_CHECK -> {
                        profileViewModel.checkUnReadNotice()
                    }

                    EventType.UPDATE_FEEDBACK_CHECK -> {
                        profileViewModel.checkUnReadFeedback()
                    }

                    else -> {}
                }
            }
        }
    }
}
