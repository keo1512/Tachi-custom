const automaticTaskIntervalHours = [
  0,
  1,
  2,
  3,
  4,
  6,
  8,
  12,
  18,
  24,
  48,
  72,
  120,
  168,
];

String taskIntervalLabel(int hours) => hours == 0
    ? 'Tắt'
    : hours >= 24 && hours % 24 == 0
    ? '${hours ~/ 24} ngày'
    : '$hours giờ';
