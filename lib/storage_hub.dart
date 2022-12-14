library storage_hub;

import 'dart:developer';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/adapter.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

const String tag = 'StorageHub';

class StorageHub {
  StorageHub._();
  static final StorageHub hub = StorageHub._();

  static bool isConfigured = false;
  static String apiEndpointBaseUrl = '';
  static String apiEndpointPostUrl = '?uploadType=resumable&name=';
  static String apiEndpointPutUrl = '?upload_id=';
  static String apiSecurityKey = '';
  static int chunkSizeInBytes = 1024 * 89;
  static int errorTreshold = 100;

  static List<FileModel> fileList = [];
  static bool isSyncing = false;
  static FileModel? syncingFile;
  static double progress = 0;

  configure({
    required String baseUrl,
    required String apiKey,
    String? postUrl = '?uploadType=resumable&name=',
    String? putUrl = '?upload_id=',
    int? chunkSize,
    int? retryCount,
  }) async {
    apiEndpointBaseUrl = baseUrl;
    apiSecurityKey = apiKey;
    if (postUrl != null) apiEndpointPostUrl = postUrl;
    if (putUrl != null) apiEndpointPutUrl = putUrl;
    if (chunkSize != null) chunkSizeInBytes = chunkSize;
    if (retryCount != null) errorTreshold = retryCount;
    isConfigured = true;
  }

  static Future<bool> addFile({
    required String filePath,
    required String fileName,
    required int totalBytes,
    Map<String, dynamic>? metadata,
    String? time,
  }) async {
    FileModel file = FileModel(
      filePath: filePath,
      fileName: fileName,
      time: time ?? DateTime.now().toIso8601String(),
      processStartTime: DateTime.now().millisecondsSinceEpoch,
      totalBytes: totalBytes,
      uploadedBytes: 0,
      status: SyncStatus.idle,
      errorCount: 0,
      metadata: metadata ?? {},
    );
    int result = await _DbProvider.db.insertFile(file: file);
    fileList = await _DbProvider.db.getFilesByStatus();
    return result > 0;
  }

  static void triggerSync() async {
    if (isSyncing) return;
    isSyncing = true;
    //
    syncingFile = await _populateFileList();
    await _startProgress();
  }

  static Future<FileModel?> _populateFileList() async {
    fileList = await _DbProvider.db.getFilesByStatus();
    if (fileList.isEmpty) return null;
    fileList.sort((a, b) => a.processStartTime ?? 0.compareTo(b.processStartTime ?? 0));
    var list = fileList.where((e) => e.status == SyncStatus.idle).toList();
    return list.isNotEmpty ? list.first : null;
  }

  static Future<void> _startProgress() async {
    if (syncingFile == null) return;
    if (syncingFile!.sessionId != null && syncingFile!.sessionId!.isNotEmpty) {
      // put
      syncingFile!.status = SyncStatus.uploading;
      _updateSyncingFileInList();
      await _DbProvider.db.updateFile(file: syncingFile!);
      syncingFile = await _NetworkProvider.putFile(file: syncingFile!);
    } else {
      // post
      syncingFile!.status = SyncStatus.requestingUpload;
      _updateSyncingFileInList();
      await _DbProvider.db.updateFile(file: syncingFile!);
      syncingFile = await _NetworkProvider.requestUpload(file: syncingFile!);
    }
    _updateSyncingFileInList();
    switch (syncingFile!.status) {
      case SyncStatus.idle:
        // not completed
        _startProgress();
        break;
      case SyncStatus.requestingUpload:
      case SyncStatus.uploading:
        // ongoing network operation
        return;
      case SyncStatus.uploaded:
        // completed
        isSyncing = false;
        syncingFile = null;
        triggerSync();
        break;
      case SyncStatus.error:
        if (syncingFile!.errorCount >= StorageHub.errorTreshold) {
          // error treshold reached -> delete file
          await _DbProvider.db.deleteFile(id: syncingFile!.id!);
        } else {
          // set file to retry again
          syncingFile!.processStartTime = DateTime.now().millisecondsSinceEpoch + (1000 * 60 * 15);
          syncingFile!.status = SyncStatus.idle;
          await _DbProvider.db.updateFile(file: syncingFile!);
        }
        isSyncing = false;
        syncingFile = null;
        triggerSync();
        break;
    }
  }

  static void _updateSyncingFileInList() {
    if (syncingFile == null || fileList.isEmpty) return;
    int index = fileList.map((e) => e.id).toList().indexOf(syncingFile!.id!);
    if (index < 0) return;
    fileList.replaceRange(index, index + 1, [syncingFile!]);
  }
}

enum SyncStatus {
  idle,
  requestingUpload,
  uploading,
  uploaded,
  error,
}

class FileModel {
  int? id;
  String? time;
  String filePath;
  String fileName;
  int totalBytes;
  int uploadedBytes;
  String? sessionId;
  SyncStatus status;
  int errorCount;
  int? processStartTime;
  Map<String, dynamic> metadata;
  FileModel({
    this.id,
    this.time,
    required this.filePath,
    required this.fileName,
    required this.totalBytes,
    required this.uploadedBytes,
    this.sessionId,
    required this.status,
    required this.errorCount,
    this.processStartTime,
    required this.metadata,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'time': time,
        'filePath': filePath,
        'fileName': fileName,
        'totalBytes': totalBytes,
        'uploadedBytes': uploadedBytes,
        'sessionId': sessionId,
        'status': status.index,
        'errorCount': errorCount,
        'processStartTime': processStartTime,
        'metadata': metadata,
      };

  Map<String, dynamic> toRow() => {
        'time': time,
        'filePath': filePath,
        'fileName': fileName,
        'totalBytes': totalBytes,
        'uploadedBytes': uploadedBytes,
        'sessionId': sessionId,
        'status': status.index,
        'errorCount': errorCount,
        'processStartTime': processStartTime,
        'metadata': metadata,
      };

  factory FileModel.fromMap(Map<String, dynamic> map) => FileModel(
        id: map['id']?.toInt(),
        time: map['time'] ?? '',
        filePath: map['filePath'] ?? '',
        fileName: map['fileName'] ?? '',
        totalBytes: map['totalBytes']?.toInt() ?? 0,
        uploadedBytes: map['uploadedBytes']?.toInt() ?? 0,
        sessionId: map['sessionId'],
        status: SyncStatus.values[map['status']],
        errorCount: map['errorCount']?.toInt() ?? 0,
        processStartTime: map['processStartTime']?.toInt(),
        metadata: Map<String, dynamic>.from(map['metadata']),
      );
}

class _DbProvider {
  _DbProvider._();
  static final _DbProvider db = _DbProvider._();
  Database? _database;

  Future<Database?> get database async {
    if (_database != null) return _database;
    _database = await initDb();
    return _database;
  }

  initDb() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, _Constants.databaseName);
    return await openDatabase(
      path,
      version: _Constants.databaseVersion,
      singleInstance: true,
      onCreate: _onCreateDb,
      onUpgrade: _onUpgradeDb,
      readOnly: false,
    );
  }

  _onCreateDb(Database db, int version) async {
    await db.execute(_Constants.dropStorageTable);
    await db.execute(_Constants.createStorageTable);
  }

  _onUpgradeDb(Database db, int oldVersion, int newVersion) async {
    // TODO: Backup data
    await db.execute(_Constants.dropStorageTable);
    await db.execute(_Constants.createStorageTable);
    // TODO: Restore data
  }

  Future<int> insertFile({required FileModel file}) async {
    final db = await database;
    if (db == null) return -1;
    try {
      int lastId = await db.insert(
        _Keys.tableName,
        file.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      return lastId;
    } catch (err) {
      log(err.toString(), name: tag);
      return -1;
    }
  }

  Future<int> deleteFile({required int id}) async {
    final db = await database;
    if (db == null) return -1;
    try {
      int deleteCount = await db.delete(
        _Keys.tableName,
        where: "${_Keys.id} = ?",
        whereArgs: ["$id"],
      );
      return deleteCount;
    } catch (err) {
      log(err.toString(), name: tag);
      return -1;
    }
  }

  Future<int> updateFile({required FileModel file}) async {
    final db = await database;
    if (db == null) return -1;
    try {
      Map<String, dynamic> row = file.toRow();
      int updateCount = await db.update(
        _Keys.tableName,
        row,
        where: "${_Keys.id} = ?",
        whereArgs: ["${file.id}"],
      );
      return updateCount;
    } catch (err) {
      log(err.toString(), name: tag);
      return -1;
    }
  }

  Future<FileModel?> getFileById({required int id}) async {
    final db = await database;
    if (db == null) return null;
    try {
      var result = await db.query(
        _Keys.tableName,
        columns: _Constants.columns,
        where: "${_Keys.id} = ?",
        whereArgs: ["$id"],
        orderBy: _Keys.id,
        limit: 1,
      );
      if (result.isNotEmpty) return FileModel.fromMap(result[0]);
    } catch (err) {
      log(err.toString(), name: tag);
    }
    return null;
  }

  Future<List<FileModel>> getFilesByStatus({SyncStatus? status}) async {
    List<FileModel> fileList = [];
    final db = await database;
    if (db == null) return fileList;
    try {
      var result = await db.query(
        _Keys.tableName,
        columns: _Constants.columns,
        where: status == null ? null : "${_Keys.syncStatus} = ?",
        whereArgs: status == null ? null : ["${status.index}"],
        orderBy: "${_Keys.id} DESC",
        limit: 1000,
      );
      if (result.isNotEmpty) {
        for (var row in result) {
          fileList.add(FileModel.fromMap(row));
        }
      }
    } catch (err) {
      log(err.toString(), name: tag);
    }
    return fileList;
  }
}

class _NetworkProvider {
  static Dio _prepareDio({Map<String, dynamic>? headers, String? contentType}) {
    Dio dio = Dio();
    if (headers != null) dio.options.headers.addAll(headers);
    if (contentType != null) dio.options.contentType = contentType;
    dio.options.followRedirects = false;
    (dio.httpClientAdapter as DefaultHttpClientAdapter).onHttpClientCreate = (HttpClient dioClient) {
      dioClient.badCertificateCallback = ((X509Certificate cert, String host, int port) => true);
      return dioClient;
    };
    return dio;
  }

  static Future<FileModel> requestUpload({required FileModel file}) async {
    Map<String, dynamic> request = file.metadata;
    request['time'] = file.time;
    request['fileName'] = file.fileName;

    Map<String, dynamic> headers = {
      "X-Api-Key": StorageHub.apiSecurityKey,
      "Content=Type": "application/json",
      "X-Upload-Content-Type": _Utils.getContentType(file.fileName),
      "X-Upload-Content-Length": file.totalBytes,
    };

    Dio dio = _prepareDio(headers: headers, contentType: "application/json");
    String url = "${StorageHub.apiEndpointBaseUrl}${StorageHub.apiEndpointPostUrl}${file.fileName}";
    Response response = await dio.post(url, data: request);
    if (response.statusCode == HttpStatus.ok || response.statusCode == HttpStatus.created) {
      if (response.data != null && response.data['success'] == true && response.data['statusCode'] == HttpStatus.ok) {
        String sessionId = response.data['data'][0]['id'];
        file.sessionId = sessionId;
        file.status = SyncStatus.idle;
      } else {
        file.status = SyncStatus.error;
      }
    } else {
      file.status = SyncStatus.error;
    }

    await _DbProvider.db.updateFile(file: file);

    return file;
  }

  static Future<FileModel> putFile({required FileModel file, Function(int, int)? progress}) async {
    //..
    String contentType = _Utils.getContentType(file.fileName);
    Map<String, dynamic> headers = {
      "X-Api-Key": StorageHub.apiSecurityKey,
      "Content=Type": contentType,
      "Content-Range": "bytes */*",
      "Accept-Encoding": "gzip,deflate,br",
      "Accept": "*/*",
      "Content-Length": math.min(StorageHub.chunkSizeInBytes, file.totalBytes - file.uploadedBytes),
    };

    Dio dio = _prepareDio(headers: headers);
    String url = "${StorageHub.apiEndpointBaseUrl}${StorageHub.apiEndpointPutUrl}${file.sessionId}";

    final int startByte = file.uploadedBytes;
    final int endByte = math.min(startByte + StorageHub.chunkSizeInBytes, file.totalBytes);
    final Stream<List<int>> chunkStream = File(file.filePath).openRead(startByte, endByte);

    Response? r;
    try {
      var response = await dio.put(
        url,
        data: chunkStream,
        onSendProgress: progress,
      );
      r = response;
    } on DioError catch (err) {
      r = err.response;
    }

    switch (r?.statusCode) {
      case HttpStatus.created:
      case HttpStatus.ok:
        file.uploadedBytes = file.totalBytes;
        file.status = SyncStatus.uploaded;
        break;
      case HttpStatus.requestedRangeNotSatisfiable:
        file.uploadedBytes = 0;
        file.status = SyncStatus.idle;
        file.errorCount++;
        file.sessionId = null;
        break;
      case HttpStatus.permanentRedirect:
        Map<String, List<String>>? map = r?.headers.map;
        String range = map!['range']![0];
        int uploadedBytes = int.parse(range.split('=')[1].split('-')[1]);
        file.uploadedBytes = uploadedBytes;
        file.status = SyncStatus.idle;
        break;
      case HttpStatus.notFound:
        file.status = SyncStatus.idle;
        file.sessionId = null;
        file.uploadedBytes = 0;
        break;
      default:
        file.status = SyncStatus.error;
        file.errorCount++;
        break;
    }
    await _DbProvider.db.updateFile(file: file);

    return file;
  }
}

class _Constants {
  static const String databaseName = 'storageHubDb.sqlite';
  static const int databaseVersion = 1;
  static const String dropStorageTable = 'DROP TABLE IF EXISTS ${_Keys.tableName}';
  static const String createStorageTable = '''
    CREATE TABLE IF NOT EXISTS ${_Keys.tableName} (
      ${_Keys.id} INTEGER PRIMARY KEY AUTOINCREMENT, 
      ${_Keys.time} TEXT, 
      ${_Keys.filePath} TEXT, 
      ${_Keys.fileName} TEXT, 
      ${_Keys.totalBytes} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.uploadedBytes} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.syncStatus} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.sessionId} TEXT, 
      ${_Keys.errorCount} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.processStartTime} INTEGER NOT NULL DEFAULT 0, 
      ${_Keys.metadata} TEXT      
    )
  ''';
  static const List<String> columns = [
    _Keys.id,
    _Keys.time,
    _Keys.filePath,
    _Keys.fileName,
    _Keys.totalBytes,
    _Keys.uploadedBytes,
    _Keys.syncStatus,
    _Keys.sessionId,
    _Keys.errorCount,
    _Keys.processStartTime,
    _Keys.metadata,
  ];
}

class _Keys {
  static const String tableName = 'storageHubFiles';
  static const String id = 'id';
  static const String time = 'time';
  static const String filePath = 'filePath';
  static const String fileName = 'fileName';
  static const String totalBytes = 'totalBytes';
  static const String uploadedBytes = 'uploadedBytes';
  static const String syncStatus = 'syncStatus';
  static const String sessionId = 'sessionId';
  static const String errorCount = 'errorCount';
  static const String processStartTime = 'processStartTime';
  static const String metadata = 'metadata';
}

class _Utils {
  static String getContentType(String fileName) {
    return "image/jpeg";
  }
}
