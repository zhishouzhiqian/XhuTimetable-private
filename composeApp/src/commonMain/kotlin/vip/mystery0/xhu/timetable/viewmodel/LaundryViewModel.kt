package vip.mystery0.xhu.timetable.viewmodel

import kotlinx.coroutines.flow.StateFlow
import vip.mystery0.xhu.timetable.base.ComposeViewModel
import vip.mystery0.xhu.timetable.laundry.LaundryServiceController
import vip.mystery0.xhu.timetable.model.laundry.LaundryUiState
import vip.mystery0.xhu.timetable.model.laundry.LaundryOrderSummary

class LaundryViewModel(
    val controller: LaundryServiceController,
) : ComposeViewModel() {
    val uiState: StateFlow<LaundryUiState> = controller.uiState
    fun init() = controller.initialize()
    fun refresh() = controller.refreshOrders()
    fun login() = controller.showLogin()
    fun beginScan() = controller.beginScan()
    fun cancelScan() = controller.cancelScan()
    fun refreshAtExpectedEnd(order: LaundryOrderSummary) = controller.refreshAtExpectedEnd(order)

    fun scanned(rawValue: String) {
        if (rawValue.isBlank()) return
        controller.onQrScanned()
    }
}
