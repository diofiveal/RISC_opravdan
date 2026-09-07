# RISC оправдан: улучшенная подсистема памяти SCR1

Экспериментальная версия открытого 32-битного RISC-V-процессора [SCR1](https://github.com/syntacore/scr1) с переработанной подсистемой памяти для FPGA.

В проект добавлены раздельные L1-кэши инструкций и данных, Victim Cache для инструкций, буфер отложенной записи и поддержка AXI burst при загрузке строк кэша. Основная FPGA-платформа — **Digilent Nexys A7-100T** с внешней DDR2.

> Актуальная реализация находится в ветке [`scr1-cache-improve`](https://github.com/diofiveal/RISC_opravdan/tree/scr1-cache-improve).

## Цель проекта

Цель работы — уменьшить время, которое SCR1 теряет в ожидании внешней памяти, сохранив небольшую и понятную микроархитектуру, пригодную для FPGA-прототипирования.

Исследуются четыре дополняющих друг друга подхода:

- повторное использование инструкций и данных в L1-кэшах;
- уменьшение конфликтных промахов I-cache с помощью Victim Cache;
- скрытие задержки write-through store через небольшой write buffer;
- более эффективная загрузка строки кэша одной AXI burst-транзакцией.

Проект также служит стендом для измерения hit/miss rate, refill-трафика, stall cycles и эффективности write buffer.

## Что реализовано

- direct-mapped L1 Instruction Cache размером 2 KiB;
- fully associative Instruction Victim Cache на 4 строки;
- swap/promotion строки из Victim Cache обратно в L1 I-cache;
- direct-mapped L1 Data Cache размером 2 KiB;
- write-through store policy;
- no-write-allocate для store miss по умолчанию;
- упорядоченный write buffer на 4 записи;
- AXI4 INCR burst для refill строк I-cache и D-cache;
- одиночные AXI-транзакции для записей;
- обход кэшей для диапазона `0xFF00_0000–0xFFFF_FFFF`;
- BRAM-ориентированные DATA/TAG-массивы;
- simulation-only performance counters;
- Tcl-скрипт для создания проекта Vivado под Nexys A7-100T.

## Архитектура
<img width="1200" height="1400" alt="Архитектура" src="https://github.com/user-attachments/assets/0e628df3-2cac-4b88-8c3d-da040f2965e5" />

Instruction и data paths используют отдельные AXI master-интерфейсы. Кэши находятся между штатными SCR1 memory routers и AXI bridges. TCM и memory-mapped timer сохраняют свои места в исходной архитектуре SCR1 и не превращаются в кэшируемую память.


## Текущая конфигурация

| Блок | Конфигурация по умолчанию | Организация |
| --- | --- | --- |
| L1 I-cache | 2 KiB, строка 8 B | Direct-mapped, blocking |
| Instruction Victim Cache | 4 строки по 8 B | Fully associative, Round-Robin |
| L1 D-cache | 2 KiB, строка 8 B | Direct-mapped, blocking |
| Write buffer | 4 записи | Упорядоченный FIFO |
| AXI read refill | 2 × 32-bit beat для строки 8 B | INCR burst, `ARLEN = 1` |
| AXI store | 1 beat | `AWLEN = 0` |

Размер строки кэша и режим burst параметризованы. Максимальная длина read burst в текущем top-level ограничена восемью beat.

## L1 Instruction Cache

I-cache хранит инструкции, поступающие из внешней памяти, и обслуживает повторные обращения без выхода на AXI.

Основные свойства:

- размер по умолчанию — 2 KiB;
- строка — 8 байт, то есть два 32-битных слова;
- direct-mapped и blocking организация;
- синхронные DATA/TAG-массивы, ориентированные на FPGA Block RAM;
- VALID-биты хранятся отдельно;
- TAG фиксируется только после успешного получения всей строки;
- при refill старая строка инвалидируется до записи новой;
- диапазон `0xFFxx_xxxx` обслуживается в bypass-режиме.

### Instruction Victim Cache

Victim Cache хранит строки, вытесненные из direct-mapped I-cache. Полный victim tag состоит из исходных TAG и INDEX, поэтому поиск выполняется ассоциативно по всем четырём записям.

При L1 miss выполняется Victim lookup:

1. При Victim hit найденная строка возвращает запрошенное слово и переносится обратно в L1.
2. Если индекс L1 уже занят, строки L1 и Victim Cache меняются местами.
3. При L1 + Victim miss вытесняемая валидная строка L1 сохраняется в Victim Cache, после чего начинается refill из памяти.
4. Запись для замещения выбирается по Round-Robin.

Такой механизм уменьшает число повторных обращений к внешней памяти при конфликтных промахах.

## L1 Data Cache

D-cache поддерживает BYTE, HALFWORD и WORD load/store с проверкой типа и выравнивания.

Основные свойства:

- размер по умолчанию — 2 KiB;
- строка — 8 байт, два 32-битных слова;
- direct-mapped и blocking организация;
- write-through: каждое cacheable store передаётся во внешнюю память;
- store hit обновляет соответствующее слово в L1;
- store miss по умолчанию использует no-write-allocate и не вытесняет текущую строку;
- load miss загружает полную строку;
- DATA RAM имеет один физический write port, общий для refill и store update;
- диапазон `0xFFxx_xxxx` работает без кэширования.

Параметр `SCR1_DCACHE_NO_WRITE_ALLOCATE` позволяет вернуть прежнее поведение write-allocate, если это требуется для эксперимента.

## Write buffer

Модуль `scr1_write_buffer.sv` отделяет завершение cacheable store со стороны процессора от более медленного ответа внешней памяти.

Write buffer представляет собой упорядоченный FIFO глубиной четыре записи. Каждая запись содержит:

- адрес;
- данные;
- ширину операции BYTE/HALFWORD/WORD.

### Как проходит store

1. D-cache передаёт cacheable store в write buffer.
2. Если FIFO не заполнен, запрос принимается, а D-cache получает локальное успешное завершение на следующем такте.
3. Процессор может продолжить работу, пока write buffer последовательно отправляет накопленные записи в backing memory.
4. Запись удаляется из FIFO только после терминального ответа внешней памяти.
5. При заполненном FIFO следующий store останавливается до освобождения записи.

В один такт разрешены одновременные dequeue старой записи и enqueue новой. Это устраняет лишний пузырь между последовательными store.

### Упорядочивание памяти

Записи уходят во внешнюю память строго в порядке поступления. Load/refill и uncached/MMIO store не обходят более старые buffered stores: сначала FIFO полностью освобождается, затем выполняется pass-through запрос. Благодаря этому сохраняется наблюдаемый порядок обращений к памяти.

MMIO-обращения в диапазон `0xFFxx_xxxx` не буферизуются.

### Ограничения текущей версии

- write combining и объединение соседних store не реализованы;
- store-to-load forwarding из FIFO не реализован — load ждёт освобождения буфера;
- записи на AXI остаются single-beat;
- поздняя ошибка backing-memory write уже не может быть возвращена завершившейся store-инструкции; вместо этого устанавливается sticky-флаг `write_error` и в simulation выводится ошибка.

## AXI burst refill

В исходном последовательном варианте каждое слово строки запрашивалось отдельной транзакцией. В текущей AXI-конфигурации I-cache и D-cache формируют один INCR burst на всю строку.

Для конфигурации по умолчанию:

```text
cache line = 8 bytes
beat size  = 4 bytes
beats      = 2
ARLEN      = beats - 1 = 1
ARSIZE     = 2  (4 bytes)
ARBURST    = INCR
```

AXI bridge выдаёт контроллеру отдельный `rvalid` для каждого принятого R-channel beat и `rlast` для последнего beat. Контроллер последовательно записывает слова в DATA RAM и делает commit TAG только после корректного завершения burst.

Реализация проверяет:

- допустимую длину burst;
- соответствие `RLAST` ожидаемому последнему слову;
- ошибки `RRESP` на любом beat;
- отсутствие перехода строки через границу AXI 4 KiB за счёт допустимых размеров и выравнивания cache line.

Если burst отключён параметром, refill снова выполняется отдельными single-beat read-запросами. AHB top-level всегда использует этот последовательный режим.

> Burst применяется только к чтению строк кэша. Store-транзакции остаются одиночными (`AWLEN = 0`).

## Cache bypass и MMIO

Адреса `0xFF00_0000–0xFFFF_FFFF` не кэшируются. Это необходимо для корректной работы UART, BRAM bootloader и других memory-mapped устройств проекта.

Для таких обращений:

- I-cache выполняет прямое чтение;
- D-cache выполняет прямой load/store;
- write buffer не подтверждает MMIO store заранее;
- перед MMIO-операцией завершаются все более старые buffered stores.

## Performance counters

Счётчики доступны при определённом `SCR1_TRGT_SIMULATION` и печатаются в конце симуляции.

### I-cache

- accesses, hits и misses;
- victim word hits и victim swaps;
- refill words и refill bursts;
- burst errors;
- stall cycles.

### D-cache и write buffer

- load/store accesses;
- hits и misses отдельно для load/store;
- store miss без allocation;
- refill words и refill bursts;
- burst errors;
- stall cycles;
- число enqueue/dequeue write buffer;
- stall cycles из-за полного FIFO;
- максимальная заполненность FIFO;
- число оставшихся записей и sticky write-error status.

Эти данные позволяют сравнивать конфигурации не только по общему времени выполнения, но и по причинам задержек.

## Основные RTL-файлы

| Файл | Назначение |
| --- | --- |
| `scr1/src/top/icache.sv` | DATA/TAG/VALID хранилище L1 I-cache |
| `scr1/src/top/icache_controller.sv` | FSM I-cache, Victim lookup/swap и refill |
| `scr1/src/top/victim_icache.sv` | Fully associative Instruction Victim Cache |
| `scr1/src/top/scr1_icache_top.sv` | Интеграция I-cache и счётчики |
| `scr1/src/top/dcache.sv` | DATA/TAG/VALID хранилище L1 D-cache |
| `scr1/src/top/dcache_controller.sv` | FSM load/store, refill и cache update |
| `scr1/src/top/scr1_write_buffer.sv` | FIFO отложенных write-through store |
| `scr1/src/top/scr1_dcache_top.sv` | Интеграция D-cache, write buffer и счётчики |
| `scr1/src/top/scr1_mem_axi.sv` | AXI bridge с потоковой выдачей read beats |
| `scr1/src/top/scr1_top_axi.sv` | Интеграция кэшей и двух AXI master paths |
| `scr1/src/top/scr1_top_ahb.sv` | AHB-интеграция без burst refill |
| `nexys_cache_victim.tcl` | Создание Vivado-проекта для Nexys A7-100T |

## Параметры для экспериментов

Основные параметры находятся в top-level модулях:

| Параметр | Значение по умолчанию | Назначение |
| --- | ---: | --- |
| `SCR1_ICACHE_LINE_BYTES` | 8 | Размер строки I-cache |
| `SCR1_DCACHE_LINE_BYTES` | 8 | Размер строки D-cache |
| `SCR1_ICACHE_AXI_BURST_ENABLE` | 1 | Burst refill I-cache |
| `SCR1_DCACHE_AXI_BURST_ENABLE` | 1 | Burst refill D-cache |
| `SCR1_AXI_MAX_READ_BURST_BEATS` | 8 | Максимальное число beat в read burst |
| `SCR1_DCACHE_NO_WRITE_ALLOCATE` | 1 | Не выделять строку при store miss |
| `SCR1_DCACHE_WRITE_BUFFER_DEPTH` | 4 | Глубина write buffer |

Последний параметр сейчас задан как `localparam` в AXI/AHB top-level, остальные доступны через параметры модулей.

## Сборка проекта для Nexys A7-100T

### Требования

- AMD/Xilinx Vivado с поддержкой Artix-7;
- board files для `digilentinc.com:nexys-a7-100t:part0:1.3`;
- установленная поддержка MIG 7 Series;
- Git.

### Создание проекта

```bash
git clone --branch scr1-cache-improve --recurse-submodules \
  https://github.com/diofiveal/RISC_opravdan.git
cd RISC_opravdan
vivado -mode batch -source nexys_cache_victim.tcl
```

Скрипт создаёт проект `nexys_a7_100t_scr1_cache_fixed` для `xc7a100tcsg324-1`, добавляет RTL, Block Design, DDR2 MIG, ограничения и стандартные synthesis/implementation runs. После выполнения скрипта проект можно открыть в Vivado и запустить synthesis, implementation и generation of bitstream.

Для другого имени проекта:

```bash
vivado -mode batch -source nexys_cache_victim.tcl \
  -tclargs --project_name my_scr1_cache_project
```

## Результаты

Текущая версия подтверждает работоспособность выбранной архитектуры подсистемы памяти на уровне RTL и FPGA-проекта:

- I-cache и D-cache интегрированы в штатные memory paths SCR1;
- Victim Cache обрабатывает конфликтные промахи с возвратом строки в L1;
- refill строки объединён в одну AXI read burst-транзакцию;
- write buffer позволяет завершать cacheable store до получения внешнего write response;
- добавлены счётчики для раздельной оценки кэшей, burst и write buffer;
- Vivado Tcl-воспроизведение проекта настроено под Nexys A7-100T и DDR2.

Ниже приведено имеющееся сравнение исходного SCR1 и версии с улучшенной подсистемой памяти. Были проведены 2 основных теста dhrystone и coremark
Под ускорением для теста dhrystone понимается отношение метрик dhrystone per sec (количество циклов dhrystone в секунду)
Под ускорением для теста coremark понимается отношение метрик Iterations/sec (количество итераций теста coremark в секунду)
<img width="1092" height="572" alt="image" src="https://github.com/user-attachments/assets/19d24e44-12b9-4e43-b9e0-4c9829c43b09" />



## Направления дальнейшей работы

- Реализация stride predictor
- Увеличение ширины AXI burst, перенос части данных полученных из burst в prefetch buffer

## Происхождение проекта

Проект основан на открытом процессорном ядре [Syntacore SCR1](https://github.com/syntacore/scr1). Исходная лицензия SCR1 находится в [`scr1/LICENSE`](scr1/LICENSE).

