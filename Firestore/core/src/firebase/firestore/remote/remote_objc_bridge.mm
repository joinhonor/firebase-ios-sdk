/*
 * Copyright 2018 Google
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "Firestore/core/src/firebase/firestore/remote/remote_objc_bridge.h"

#import <Foundation/Foundation.h>

#include <iomanip>
#include <map>
#include <sstream>
#include <utility>
#include <vector>

#import "Firestore/Protos/objc/google/firestore/v1/Firestore.pbobjc.h"
#import "Firestore/Source/API/FIRFirestore+Internal.h"

#include "Firestore/core/src/firebase/firestore/model/snapshot_version.h"
#include "Firestore/core/src/firebase/firestore/nanopb/byte_string.h"
#include "Firestore/core/src/firebase/firestore/nanopb/nanopb_util.h"
#include "Firestore/core/src/firebase/firestore/nanopb/writer.h"
#include "Firestore/core/src/firebase/firestore/remote/grpc_util.h"
#include "Firestore/core/src/firebase/firestore/util/error_apple.h"
#include "Firestore/core/src/firebase/firestore/util/hard_assert.h"
#include "Firestore/core/src/firebase/firestore/util/status.h"
#include "Firestore/core/src/firebase/firestore/util/statusor.h"
#include "Firestore/core/src/firebase/firestore/util/string_apple.h"
#include "grpcpp/support/status.h"

namespace firebase {
namespace firestore {
namespace remote {
namespace bridge {

using core::DatabaseInfo;
using local::QueryData;
using model::DocumentKey;
using model::MaybeDocument;
using model::Mutation;
using model::MutationResult;
using model::TargetId;
using model::SnapshotVersion;
using nanopb::ByteString;
using nanopb::ByteStringWriter;
using nanopb::MakeByteString;
using nanopb::MakeNSData;
using nanopb::Message;
using remote::Serializer;
using util::MakeString;
using util::MakeNSError;
using util::Status;
using util::StatusOr;
using util::StringFormat;

namespace {

NSData* ConvertToNsData(const grpc::ByteBuffer& buffer, NSError** out_error) {
  std::vector<grpc::Slice> slices;
  grpc::Status status = buffer.Dump(&slices);
  if (!status.ok()) {
    *out_error = MakeNSError(Status{
        Error::Internal, "Trying to convert an invalid grpc::ByteBuffer"});
    return nil;
  }

  if (slices.size() == 1) {
    return [NSData dataWithBytes:slices.front().begin()
                          length:slices.front().size()];
  } else {
    NSMutableData* data = [NSMutableData dataWithCapacity:buffer.Length()];
    for (const auto& slice : slices) {
      [data appendBytes:slice.begin() length:slice.size()];
    }
    return data;
  }
}

template <typename T>
grpc::ByteBuffer ConvertToByteBuffer(const pb_field_t* fields,
                                     const T& request) {
  ByteStringWriter writer;
  writer.WriteNanopbMessage(fields, &request);
  ByteString bytes = writer.Release();

  grpc::Slice slice{bytes.data(), bytes.size()};
  return grpc::ByteBuffer{&slice, 1};
}

template <typename T, typename U>
std::string DescribeRequest(const pb_field_t* fields, const U& request) {
  // FIXME inefficient implementation.
  auto bytes = ConvertToByteBuffer(fields, request);
  auto ns_data = ConvertToNsData(bytes, nil);
  T* objc_request = [T parseFromData:ns_data error:nil];
  return util::MakeString([objc_request description]);
}

}  // namespace

bool IsLoggingEnabled() {
  return [FIRFirestore isLoggingEnabled];
}

// WatchStreamSerializer

WatchStreamSerializer::WatchStreamSerializer(Serializer serializer)
    : serializer_{std::move(serializer)} {
}

google_firestore_v1_ListenRequest WatchStreamSerializer::CreateWatchRequest(
    const QueryData& query) const {
  google_firestore_v1_ListenRequest request{};

  request.database = serializer_.EncodeDatabaseId();
  request.which_target_change =
      google_firestore_v1_ListenRequest_add_target_tag;
  request.add_target = serializer_.EncodeTarget(query);

  auto labels = serializer_.EncodeListenRequestLabels(query);
  if (!labels.empty()) {
    request.labels_count = nanopb::CheckedSize(labels.size());
    request.labels = MakeArray<google_firestore_v1_ListenRequest_LabelsEntry>(
        request.labels_count);

    pb_size_t i = 0;
    for (const auto& kv : labels) {
      request.labels[i].key = Serializer::EncodeString(kv.first);
      request.labels[i].value = Serializer::EncodeString(kv.second);
      ++i;
    }
  }

  return request;
}

google_firestore_v1_ListenRequest WatchStreamSerializer::CreateUnwatchRequest(
    TargetId target_id) const {
  google_firestore_v1_ListenRequest request{};

  request.database = serializer_.EncodeDatabaseId();
  request.which_target_change =
      google_firestore_v1_ListenRequest_remove_target_tag;
  request.remove_target = target_id;

  return request;
}

Message<google_firestore_v1_ListenResponse>
WatchStreamSerializer::ParseResponse(const grpc::ByteBuffer& message) const {
  return Message<google_firestore_v1_ListenResponse>(
      google_firestore_v1_ListenResponse_fields, message);
}

std::unique_ptr<WatchChange> WatchStreamSerializer::ToWatchChange(
    const google_firestore_v1_ListenResponse& response) const {
  nanopb::Reader reader;
  return serializer_.DecodeWatchChange(&reader, response);
}

SnapshotVersion WatchStreamSerializer::ToSnapshotVersion(
    const google_firestore_v1_ListenResponse& response) const {
  nanopb::Reader reader;
  return serializer_.DecodeVersion(&reader, response);
}

std::string WatchStreamSerializer::Describe(
    const google_firestore_v1_ListenRequest& request) {
  return DescribeRequest<GCFSListenRequest>(
      google_firestore_v1_ListenRequest_fields, request);
}

std::string WatchStreamSerializer::Describe(
    const google_firestore_v1_ListenResponse& response) {
  return DescribeRequest<GCFSListenResponse>(
      google_firestore_v1_ListenResponse_fields, response);
}

// WriteStreamSerializer

WriteStreamSerializer::WriteStreamSerializer(Serializer serializer)
    : serializer_{std::move(serializer)} {
}

google_firestore_v1_WriteRequest WriteStreamSerializer::CreateHandshake()
    const {
  // The initial request cannot contain mutations, but must contain a project
  // ID.
  google_firestore_v1_WriteRequest request{};
  request.database = serializer_.EncodeDatabaseId();
  return request;
}

google_firestore_v1_WriteRequest
WriteStreamSerializer::CreateWriteMutationsRequest(
    const std::vector<Mutation>& mutations,
    const ByteString& last_stream_token) const {
  google_firestore_v1_WriteRequest request{};

  if (!mutations.empty()) {
    request.writes_count = nanopb::CheckedSize(mutations.size());
    request.writes = MakeArray<google_firestore_v1_Write>(request.writes_count);

    for (pb_size_t i = 0; i != request.writes_count; ++i) {
      request.writes[i] = serializer_.EncodeMutation(mutations[i]);
    }
  }

  request.stream_token = nanopb::CopyBytesArray(last_stream_token.get());

  return request;
}

Message<google_firestore_v1_WriteResponse> WriteStreamSerializer::ParseResponse(
    const grpc::ByteBuffer& message) const {
  return Message<google_firestore_v1_WriteResponse>(
      google_firestore_v1_WriteResponse_fields, message);
}

model::SnapshotVersion WriteStreamSerializer::ToCommitVersion(
    const google_firestore_v1_WriteResponse& proto) const {
  nanopb::Reader reader;
  auto result = serializer_.DecodeSnapshotVersion(&reader, proto.commit_time);
  // FIXME check error
  return result;
}

std::vector<MutationResult> WriteStreamSerializer::ToMutationResults(
    const google_firestore_v1_WriteResponse& proto) const {
  const SnapshotVersion commit_version = ToCommitVersion(proto);

  const google_firestore_v1_WriteResult* writes = proto.write_results;
  pb_size_t count = proto.write_results_count;
  std::vector<MutationResult> results;
  results.reserve(count);

  nanopb::Reader reader;
  for (pb_size_t i = 0; i != count; ++i) {
    results.push_back(
        serializer_.DecodeMutationResult(&reader, writes[i], commit_version));
  };

  // FIXME check error
  return results;
}

std::string WriteStreamSerializer::Describe(
    const google_firestore_v1_WriteRequest& request) {
  return DescribeRequest<GCFSWriteRequest>(
      google_firestore_v1_WriteRequest_fields, request);
}

std::string WriteStreamSerializer::Describe(
    const google_firestore_v1_WriteResponse& response) {
  return DescribeRequest<GCFSWriteResponse>(
      google_firestore_v1_WriteResponse_fields, response);
}

// DatastoreSerializer

DatastoreSerializer::DatastoreSerializer(const DatabaseInfo& database_info)
    : serializer_{database_info.database_id()} {
}

google_firestore_v1_CommitRequest DatastoreSerializer::CreateCommitRequest(
    const std::vector<Mutation>& mutations) const {
  google_firestore_v1_CommitRequest request{};

  request.database = serializer_.EncodeDatabaseId();

  if (!mutations.empty()) {
    request.writes_count = nanopb::CheckedSize(mutations.size());
    request.writes = MakeArray<google_firestore_v1_Write>(request.writes_count);
    pb_size_t i = 0;
    for (const Mutation& mutation : mutations) {
      request.writes[i] = serializer_.EncodeMutation(mutation);
      ++i;
    }
  }

  return request;
}

google_firestore_v1_BatchGetDocumentsRequest
DatastoreSerializer::CreateLookupRequest(
    const std::vector<DocumentKey>& keys) const {
  google_firestore_v1_BatchGetDocumentsRequest request{};

  request.database = serializer_.EncodeDatabaseId();
  if (!keys.empty()) {
    request.documents_count = nanopb::CheckedSize(keys.size());
    request.documents = MakeArray<pb_bytes_array_t*>(request.documents_count);
    pb_size_t i = 0;
    for (const DocumentKey& key : keys) {
      request.documents[i] = serializer_.EncodeKey(key);
      ++i;
    }
  }

  return request;
}

StatusOr<std::vector<model::MaybeDocument>>
DatastoreSerializer::MergeLookupResponses(
    const std::vector<grpc::ByteBuffer>& responses) const {
  // Sort by key.
  std::map<DocumentKey, MaybeDocument> results;

  for (const auto& response : responses) {
    Message<google_firestore_v1_BatchGetDocumentsResponse> maybe_proto{
            google_firestore_v1_BatchGetDocumentsResponse_fields, response};
    if (!maybe_proto.ok()) {
      return maybe_proto.status();
    }

    const auto& proto = maybe_proto.ValueOrDie();
    nanopb::Reader reader;
    MaybeDocument doc = serializer_.DecodeMaybeDocument(&reader, proto);
    results[doc.key()] = std::move(doc);
  }

  std::vector<MaybeDocument> docs;
  docs.reserve(results.size());
  for (const auto& kv : results) {
    docs.push_back(kv.second);
  }

  StatusOr<std::vector<model::MaybeDocument>> result{std::move(docs)};
  return result;
}

MaybeDocument DatastoreSerializer::ToMaybeDocument(
    const google_firestore_v1_BatchGetDocumentsResponse& response) const {
  nanopb::Reader reader;
  return serializer_.DecodeMaybeDocument(&reader, response);
}

}  // namespace bridge
}  // namespace remote
}  // namespace firestore
}  // namespace firebase
