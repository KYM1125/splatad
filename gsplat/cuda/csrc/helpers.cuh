#ifndef GSPLAT_CUDA_HELPERS_H
#define GSPLAT_CUDA_HELPERS_H

#include "third_party/glm/glm/glm.hpp"
#include "third_party/glm/glm/gtc/type_ptr.hpp"
#include <cooperative_groups.h>
#include <cooperative_groups/reduce.h>

#include <ATen/cuda/Atomic.cuh>

#define PRAGMA_UNROLL _Pragma("unroll")

#define RAD_TO_DEG 57.2957795131f

namespace cg = cooperative_groups;

template <uint32_t DIM, class T, class WarpT>
inline __device__ void warpSum(T *val, WarpT &warp) {
    PRAGMA_UNROLL
    for (uint32_t i = 0; i < DIM; i++) {
        val[i] = cg::reduce(warp, val[i], cg::plus<T>());
    }
}

template <class WarpT> inline __device__ void warpSum(float3 &val, WarpT &warp) {
    val.x = cg::reduce(warp, val.x, cg::plus<float>());
    val.y = cg::reduce(warp, val.y, cg::plus<float>());
    val.z = cg::reduce(warp, val.z, cg::plus<float>());
}

template <class WarpT> inline __device__ void warpSum(float2 &val, WarpT &warp) {
    val.x = cg::reduce(warp, val.x, cg::plus<float>());
    val.y = cg::reduce(warp, val.y, cg::plus<float>());
}

template <class WarpT> inline __device__ void warpSum(float &val, WarpT &warp) {
    val = cg::reduce(warp, val, cg::plus<float>());
}

template <class WarpT> inline __device__ void warpSum(glm::vec4 &val, WarpT &warp) {
    val.x = cg::reduce(warp, val.x, cg::plus<float>());
    val.y = cg::reduce(warp, val.y, cg::plus<float>());
    val.z = cg::reduce(warp, val.z, cg::plus<float>());
    val.w = cg::reduce(warp, val.w, cg::plus<float>());
}

template <class WarpT> inline __device__ void warpSum(glm::vec3 &val, WarpT &warp) {
    val.x = cg::reduce(warp, val.x, cg::plus<float>());
    val.y = cg::reduce(warp, val.y, cg::plus<float>());
    val.z = cg::reduce(warp, val.z, cg::plus<float>());
}

template <class WarpT> inline __device__ void warpSum(glm::vec2 &val, WarpT &warp) {
    val.x = cg::reduce(warp, val.x, cg::plus<float>());
    val.y = cg::reduce(warp, val.y, cg::plus<float>());
}

template <class WarpT> inline __device__ void warpSum(glm::mat4 &val, WarpT &warp) {
    warpSum(val[0], warp);
    warpSum(val[1], warp);
    warpSum(val[2], warp);
    warpSum(val[3], warp);
}

template <class WarpT> inline __device__ void warpSum(glm::mat3 &val, WarpT &warp) {
    warpSum(val[0], warp);
    warpSum(val[1], warp);
    warpSum(val[2], warp);
}

template <class WarpT> inline __device__ void warpSum(glm::mat2 &val, WarpT &warp) {
    warpSum(val[0], warp);
    warpSum(val[1], warp);
}

template <class WarpT> inline __device__ void warpMax(float &val, WarpT &warp) {
    val = cg::reduce(warp, val, cg::greater<float>());
}

inline __device__ void compute_pix_velocity(
    const glm::vec3 p_view,
    const glm::vec3 lin_vel,
    const glm::vec3 ang_vel,
    const glm::vec3 vel_view,
    const float fx,
    const float fy,
    const float cx,
    const float cy,
    const uint32_t width,
    const uint32_t height,
    glm::vec2 &total_vel_pix
) {

    float x = p_view[0], y = p_view[1], z = p_view[2];

    float tan_fovx = 0.5f * width / fx;
    float tan_fovy = 0.5f * height / fy;
    float lim_x_pos = (width - cx) / fx + 0.3f * tan_fovx;
    float lim_x_neg = cx / fx + 0.3f * tan_fovx;
    float lim_y_pos = (height - cy) / fy + 0.3f * tan_fovy;
    float lim_y_neg = cy / fy + 0.3f * tan_fovy;

    float rz = 1.f / z;
    float rz2 = rz * rz;
    float tx = z * min(lim_x_pos, max(-lim_x_neg, x * rz));
    float ty = z * min(lim_y_pos, max(-lim_y_neg, y * rz));

    // mat3x2 is 3 columns x 2 rows.
    glm::mat3x2 J = glm::mat3x2(fx * rz, 0.f,                  // 1st column
                                0.f, fy * rz,                  // 2nd column
                                -fx * tx * rz2, -fy * ty * rz2 // 3rd column
    );

    glm::vec3 rot_part = glm::cross(ang_vel, p_view);
    glm::vec3 total_vel = lin_vel + rot_part - vel_view;
    // negative sign: move points to the opposite direction as the camera
    total_vel_pix = -J * total_vel;
}

inline __device__ void compute_lidar_velocity(
    const glm::vec3 p_view,
    const glm::vec3 lin_vel,
    const glm::vec3 ang_vel,
    const glm::vec3 vel_view,
    glm::mat3 &J,
    glm::vec3 &total_vel_pix
) {
    glm::vec3 rot_part = glm::cross(ang_vel, p_view);
    glm::vec3 total_vel = lin_vel + rot_part - vel_view;

    if (glm::length(J[0]) == 0) {
        const float x2 = p_view.x * p_view.x;
        const float y2 = p_view.y * p_view.y;
        const float z2 = p_view.z * p_view.z;
        const float r2 = x2 + y2 + z2;
        const float rinv = rsqrtf(r2);
        const float sqrtx2y2 = hypotf(p_view.x, p_view.y);
        const float sqrtx2y2_inv = rhypotf(p_view.x, p_view.y);
        const float xz = p_view.x * p_view.z;
        const float yz = p_view.y * p_view.z;
        const float r2sqrtx2y2_inv = 1.f / (r2) * sqrtx2y2_inv;

        // column major, mat3x2 is 3 columns x 2 rows.
        J = glm::mat3(
            -p_view.y / (x2 + y2) * RAD_TO_DEG, -xz * r2sqrtx2y2_inv * RAD_TO_DEG, p_view.x * rinv, // 1st column
            p_view.x / (x2 + y2) * RAD_TO_DEG,  -yz * r2sqrtx2y2_inv * RAD_TO_DEG, p_view.y * rinv,// 2nd column
            0.f                  ,                      sqrtx2y2 / r2 * RAD_TO_DEG,   p_view.z * rinv    // 3rd column
        );
    }

    // negative sign: move points to the opposite direction as the camera
    total_vel_pix = -J * total_vel;
}

inline __device__ void compute_and_sum_pix_velocity_vjp(
    const glm::vec3 p_view,
    const glm::vec3 lin_vel,
    const glm::vec3 ang_vel,
    const glm::vec3 vel_view,
    const float fx,
    const float fy,
    const float cx,
    const float cy,
    const uint32_t width,
    const uint32_t height,
    const glm::vec2 v_pix_velocity,
    glm::vec3 &v_p_view_accumulator,
    glm::vec3 &v_vel_view)
{
    float x = p_view[0], y = p_view[1], z = p_view[2];

    float tan_fovx = 0.5f * width / fx;
    float tan_fovy = 0.5f * height / fy;
    float lim_x_pos = (width - cx) / fx + 0.3f * tan_fovx;
    float lim_x_neg = cx / fx + 0.3f * tan_fovx;
    float lim_y_pos = (height - cy) / fy + 0.3f * tan_fovy;
    float lim_y_neg = cy / fy + 0.3f * tan_fovy;

    float rz = 1.f / z;
    float rz2 = rz * rz;
    float tx = z * min(lim_x_pos, max(-lim_x_neg, x * rz));
    float ty = z * min(lim_y_pos, max(-lim_y_neg, y * rz));

    // mat3x2 is 3 columns x 2 rows.
    glm::mat3x2 J = glm::mat3x2(fx * rz, 0.f,                  // 1st column
                                0.f, fy * rz,                  // 2nd column
                                -fx * tx * rz2, -fy * ty * rz2 // 3rd column
    );

    glm::vec3 rot_part = glm::cross(ang_vel, p_view);
    glm::vec3 total_vel = lin_vel + rot_part - vel_view;

    glm::mat3x2 dJ_dz = glm::mat3x2(
        -fx * rz2,
        0.f,
        0.f,
        -fy * rz2,
        2.f * fx * tx * rz2 * rz,
        2.f * fy * ty * rz2 * rz
    );

    if (x * rz <= lim_x_pos && x * rz >= -lim_x_neg) {
        v_p_view_accumulator.x += v_pix_velocity.x * fx * rz2 * total_vel.z; //-glm::dot(v_pix_velocity, dJ_dx * total_vel);
    } else {
        v_p_view_accumulator.z += v_pix_velocity.x * fx * rz2 * rz * tx * total_vel.z; //-glm::dot(v_pix_velocity, dJ_dx * rz * tx * total_vel);
    }
    if (y * rz <= lim_y_pos && y * rz >= -lim_y_neg) {
        v_p_view_accumulator.y += v_pix_velocity.y * fy * rz2 * total_vel.z; //glm::dot(v_pix_velocity, dJ_dy * total_vel);
    } else {
        v_p_view_accumulator.z += v_pix_velocity.y * fy * rz2 * rz * ty * total_vel.z; // glm::dot(v_pix_velocity, dJ_dy * rz * ty * total_vel);
    }
    v_p_view_accumulator.z -= glm::dot(v_pix_velocity, dJ_dz * total_vel);

    glm::vec3 v_rot_part = -glm::transpose(J) * v_pix_velocity; // = v_total_vel

    // (v_rot_part^T * cross_prod_matrix(ang_vel))^T
    // = cross_prod_matrix(ang_vel)^T * v_rot_part // ... skew-symmetry
    // = -cross_prod_matrix(ang_vel) * v_rot_part
    // = -cross(ang_vel, v_rot_part)
    glm::vec3 v_p_view_rot = -glm::cross(ang_vel, v_rot_part);

    v_p_view_accumulator.x += v_p_view_rot[0];
    v_p_view_accumulator.y += v_p_view_rot[1];
    v_p_view_accumulator.z += v_p_view_rot[2];

    v_vel_view -= v_rot_part;
}

inline __device__ void compute_and_sum_lidar_velocity_vjp(
    const glm::vec3 p_view,
    const glm::vec3 lin_vel,
    const glm::vec3 ang_vel,
    const glm::vec3 vel_view,
    const glm::vec3 v_pix_velocity,
    glm::vec3 &v_p_view_accumulator,
    glm::vec3 &v_vel_view)
{
    glm::vec3 rot_part = glm::cross(ang_vel, p_view);
    glm::vec3 total_vel = lin_vel + rot_part - vel_view;

    const float x = p_view.x;
    const float y = p_view.y;
    const float z = p_view.z;
    const float x2 = x * x;
    const float y2 = y * y;
    const float z2 = z * z;
    const float x4 = x2 * x2;
    const float y4 = y2 * y2;
    const float x2plusy2 = x2 + y2;
    const float sqrtx2y2 = hypot(x, y);
    const float sqrtx2y2_inv = rhypot(x, y);
    const float x2plusy2squared = x2plusy2 * x2plusy2;
    const float x2plusy2pow3by2 = sqrtx2y2 * x2plusy2;
    const float r2 = x2 + y2 + z2;
    const float r4 = r2 * r2;
    const float rinv = rsqrtf(r2);
    const float r3_inv = 1 / r2 * rinv;
    const float xz = x * z;
    const float xy = x * y;
    const float yz = y * z;
    const float r2sqrtx2y2_inv = 1.f / (r2) * sqrtx2y2_inv;
    const float xyz = x * y * z;
    const float denom1 = 1.f / (x2plusy2pow3by2 * r4);
    const float denom2 = 1.f / r4 * sqrtx2y2_inv;

    // column major, mat3x2 is 3 columns x 2 rows.
    glm::mat3 J = glm::mat3(
        -p_view.y / (x2 + y2) * RAD_TO_DEG, -xz * r2sqrtx2y2_inv * RAD_TO_DEG, p_view.x * rinv, // 1st column
        p_view.x / (x2 + y2) * RAD_TO_DEG,  -yz * r2sqrtx2y2_inv * RAD_TO_DEG, p_view.y * rinv, // 2nd column
        0.f,                                        sqrtx2y2 / r2 * RAD_TO_DEG,   p_view.z * rinv  // 3rd column
    );


    glm::mat3 dJ_dx = glm::mat3(
        2.f * xy / x2plusy2squared * RAD_TO_DEG , z * (2.f * x4 + x2 * y2 - y2 * (y2 + z2)) * denom1 * RAD_TO_DEG, (y2 + z2) * r3_inv,
        (y2 - x2) / x2plusy2squared * RAD_TO_DEG, xyz * (3.f * x2 + 3.f * y2 + z2) * denom1 * RAD_TO_DEG       , - xy * r3_inv,
        0.f                                            , -x * (x2 + y2 - z2) * denom2 * RAD_TO_DEG                      , - xz * r3_inv
    );

    glm::mat3 dJ_dy = glm::mat3(
        (y2 - x2) / x2plusy2squared * RAD_TO_DEG, xyz * (3.f * x2 + 3.f * y2 + z2) * denom1 * RAD_TO_DEG     , - xy * r3_inv,
        -2.f * xy / x2plusy2squared * RAD_TO_DEG, -z * (x4 + x2 * (z2 - y2) - 2.f * y4) * denom1 * RAD_TO_DEG, (x2 + z2) * r3_inv,
        0.f                                            , -y * (x2 + y2 - z2) * denom2 * RAD_TO_DEG                  , - yz * r3_inv
    );

    glm::mat3 dJ_dz = glm::mat3(
        0.f                        , -x * (x2 + y2 - z2) * denom2 * RAD_TO_DEG, - xz * r3_inv,
        0.f                        , -y * (x2 + y2 - z2) * denom2 * RAD_TO_DEG, - yz * r3_inv,
        0.f                        , -2.f * z * sqrtx2y2 / r4 * RAD_TO_DEG    , (x2 + y2) * r3_inv
    );

    v_p_view_accumulator.x -= glm::dot(v_pix_velocity, dJ_dx * total_vel);
    v_p_view_accumulator.y -= glm::dot(v_pix_velocity, dJ_dy * total_vel);
    v_p_view_accumulator.z -= glm::dot(v_pix_velocity, dJ_dz * total_vel);

    glm::vec3 v_rot_part = -glm::transpose(J) * v_pix_velocity; // = v_total_vel

    // (v_rot_part^T * cross_prod_matrix(ang_vel))^T
    // = cross_prod_matrix(ang_vel)^T * v_rot_part // ... skew-symmetry
    // = -cross_prod_matrix(ang_vel) * v_rot_part
    // = -cross(ang_vel, v_rot_part)
    glm::vec3 v_p_view_rot = -glm::cross(ang_vel, v_rot_part);

    v_p_view_accumulator.x += v_p_view_rot[0];
    v_p_view_accumulator.y += v_p_view_rot[1];
    v_p_view_accumulator.z += v_p_view_rot[2];

    v_vel_view -= v_rot_part;
}

#endif // GSPLAT_CUDA_HELPERS_H