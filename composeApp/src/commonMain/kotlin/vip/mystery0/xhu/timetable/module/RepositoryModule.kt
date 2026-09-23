package vip.mystery0.xhu.timetable.module

import org.koin.dsl.module
import org.koin.core.qualifier.named
import vip.mystery0.xhu.timetable.repository.PerfectCampusRepository
import vip.mystery0.xhu.timetable.repository.WaterRepository
import vip.mystery0.xhu.timetable.water.WaterServiceController

val repositoryModule = module {
    single { PerfectCampusRepository(get(named(HTTP_CLIENT_WATER))) }
    single { WaterRepository(get()) }
    single { WaterServiceController(get(), get()) }
}
