package vip.mystery0.xhu.timetable.module

import org.koin.dsl.module
import vip.mystery0.xhu.timetable.repository.WaterRepository

val repositoryModule = module {
    single { WaterRepository(get()) }
}
