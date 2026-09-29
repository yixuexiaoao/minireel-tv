enum DramaChannel {
  real('真人剧', 'real-drama'),
  comicDrama('漫剧', 'comic-drama'),
  ai('AI剧', 'ai-drama'),
  animation('动漫', 'comic');

  const DramaChannel(this.label, this.route);
  final String label;
  final String route;

  static DramaChannel parse(String? value) =>
      values.firstWhere((channel) => channel.name == value, orElse: () => real);
}

enum ReleaseStatus { ongoing, completed, unknown }

final class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.sourceId,
    required this.title,
    this.coverUrl = '',
    this.intro = '',
    this.category = '',
    this.episodeCount = 0,
    this.remark = '',
    this.tags = const [],
    this.channel = DramaChannel.real,
    this.releaseStatus = ReleaseStatus.unknown,
    this.score,
    this.views,
    this.heat,
    this.onlineDate,
  });

  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String coverUrl;
  final String intro;
  final String category;
  final int episodeCount;
  final String remark;
  final List<String> tags;
  final DramaChannel channel;
  final ReleaseStatus releaseStatus;
  final double? score;
  final int? views;
  final double? heat;
  final DateTime? onlineDate;

  Drama copyWith({
    String? id,
    String? source,
    String? sourceId,
    String? title,
    String? coverUrl,
    String? intro,
    String? category,
    int? episodeCount,
    String? remark,
    List<String>? tags,
    DramaChannel? channel,
    ReleaseStatus? releaseStatus,
    double? score,
    int? views,
    double? heat,
    DateTime? onlineDate,
  }) => Drama(
    id: id ?? this.id,
    source: source ?? this.source,
    sourceId: sourceId ?? this.sourceId,
    title: title ?? this.title,
    coverUrl: coverUrl ?? this.coverUrl,
    intro: intro ?? this.intro,
    category: category ?? this.category,
    episodeCount: episodeCount ?? this.episodeCount,
    remark: remark ?? this.remark,
    tags: tags ?? this.tags,
    channel: channel ?? this.channel,
    releaseStatus: releaseStatus ?? this.releaseStatus,
    score: score ?? this.score,
    views: views ?? this.views,
    heat: heat ?? this.heat,
    onlineDate: onlineDate ?? this.onlineDate,
  );

  /// Sparse search/rank records must not erase richer cached metadata.
  Drama mergeMissing(Drama? previous, {bool preserveChannel = false}) {
    if (previous == null || previous.id != id) return this;
    final validPrevCover = (previous.coverUrl.contains('.heic')) ? '' : previous.coverUrl;
    final finalCover = coverUrl.isNotEmpty && !coverUrl.contains('.heic')
        ? coverUrl
        : validPrevCover;
    return Drama(
      id: id,
      source: source,
      sourceId: sourceId,
      title: title.isEmpty || title == sourceId ? previous.title : title,
      coverUrl: finalCover,
      intro: intro.isEmpty ? previous.intro : intro,
      category: category.isEmpty || category == channel.label
          ? previous.category
          : category,
      episodeCount: episodeCount > 0 ? episodeCount : previous.episodeCount,
      remark: remark.isEmpty ? previous.remark : remark,
      tags: tags.isEmpty ? previous.tags : tags,
      channel: preserveChannel ? previous.channel : channel,
      releaseStatus: releaseStatus == ReleaseStatus.unknown
          ? previous.releaseStatus
          : releaseStatus,
      score: score ?? previous.score,
      views: views ?? previous.views,
      heat: heat ?? previous.heat,
      onlineDate: onlineDate ?? previous.onlineDate,
    );
  }

  String get episodeLabel => remark.isNotEmpty
      ? remark
      : episodeCount > 0
      ? '全 $episodeCount 集'
      : '查看剧集';

  String get subtitle => [
    if (episodeCount > 0) '$episodeCount 集',
    category.isEmpty ? channel.label : category,
  ].join(' · ');

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    return [
      title,
      category,
      channel.label,
      ...tags,
    ].any((value) => value.toLowerCase().contains(q));
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'coverUrl': coverUrl,
    'intro': intro,
    'category': category,
    'episodeCount': episodeCount,
    'remark': remark,
    'tags': tags,
    'channel': channel.name,
    'releaseStatus': releaseStatus.name,
    'score': score,
    'views': views,
    'heat': heat,
    'onlineDate': onlineDate?.toIso8601String(),
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String,
    source: json['source'] as String,
    sourceId: json['sourceId'] as String,
    title: json['title'] as String,
    coverUrl: json['coverUrl'] as String? ?? '',
    intro: json['intro'] as String? ?? '',
    category: json['category'] as String? ?? '',
    episodeCount: (json['episodeCount'] as num?)?.toInt() ?? 0,
    remark: json['remark'] as String? ?? '',
    tags: (json['tags'] as List?)?.cast<String>() ?? const [],
    channel: DramaChannel.parse(json['channel'] as String?),
    releaseStatus: ReleaseStatus.values.firstWhere(
      (value) => value.name == json['releaseStatus'],
      orElse: () => ReleaseStatus.unknown,
    ),
    score: (json['score'] as num?)?.toDouble(),
    views: (json['views'] as num?)?.toInt(),
    heat: (json['heat'] as num?)?.toDouble(),
    onlineDate: DateTime.tryParse(json['onlineDate'] as String? ?? ''),
  );
}

final class Episode {
  const Episode({
    required this.id,
    required this.dramaId,
    required this.sourceEpisodeId,
    required this.index,
  });

  final String id;
  final String dramaId;
  final String sourceEpisodeId;

  /// The episode number shown to viewers is one based.
  final int index;
  String get title => '第 $index 集';

  Map<String, dynamic> toJson() => {
    'id': id,
    'dramaId': dramaId,
    'sourceEpisodeId': sourceEpisodeId,
    'index': index,
  };

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
    id: json['id'] as String,
    dramaId: json['dramaId'] as String,
    sourceEpisodeId: json['sourceEpisodeId'] as String,
    index: json['index'] as int,
  );
}

final class DramaDetail {
  const DramaDetail({required this.drama, required this.episodes});
  final Drama drama;
  final List<Episode> episodes;

  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episodes': episodes.map((episode) => episode.toJson()).toList(),
  };

  factory DramaDetail.fromJson(Map<String, dynamic> json) => DramaDetail(
    drama: Drama.fromJson(json['drama'] as Map<String, dynamic>),
    episodes: (json['episodes'] as List)
        .map((item) => Episode.fromJson(item as Map<String, dynamic>))
        .toList(growable: false),
  );
}
