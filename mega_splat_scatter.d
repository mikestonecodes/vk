; SPIR-V
; Version: 1.6
; Generator: Google spiregg; 0
; Bound: 100
; Schema: 0
               OpCapability Shader
          %1 = OpExtInstImport "GLSL.std.450"
               OpMemoryModel Logical GLSL450
               OpEntryPoint GLCompute %main "main" %gl_GlobalInvocationID %push_constants %density_texture
               OpExecutionMode %main LocalSize 128 1 1
               OpSource HLSL 600
               OpName %type_PushConstant_PushConstants "type.PushConstant.PushConstants"
               OpMemberName %type_PushConstant_PushConstants 0 "time"
               OpMemberName %type_PushConstant_PushConstants 1 "delta_time"
               OpMemberName %type_PushConstant_PushConstants 2 "particle_count"
               OpMemberName %type_PushConstant_PushConstants 3 "_pad0"
               OpMemberName %type_PushConstant_PushConstants 4 "screen_width"
               OpMemberName %type_PushConstant_PushConstants 5 "screen_height"
               OpMemberName %type_PushConstant_PushConstants 6 "brightness"
               OpMemberName %type_PushConstant_PushConstants 7 "blur_radius"
               OpMemberName %type_PushConstant_PushConstants 8 "blur_sigma"
               OpMemberName %type_PushConstant_PushConstants 9 "_pad1"
               OpMemberName %type_PushConstant_PushConstants 10 "_pad2"
               OpMemberName %type_PushConstant_PushConstants 11 "_pad3"
               OpName %push_constants "push_constants"
               OpName %type_2d_image "type.2d.image"
               OpName %density_texture "density_texture"
               OpName %main "main"
               OpDecorate %gl_GlobalInvocationID BuiltIn GlobalInvocationId
               OpDecorate %density_texture DescriptorSet 0
               OpDecorate %density_texture Binding 0
               OpMemberDecorate %type_PushConstant_PushConstants 0 Offset 0
               OpMemberDecorate %type_PushConstant_PushConstants 1 Offset 4
               OpMemberDecorate %type_PushConstant_PushConstants 2 Offset 8
               OpMemberDecorate %type_PushConstant_PushConstants 3 Offset 12
               OpMemberDecorate %type_PushConstant_PushConstants 4 Offset 16
               OpMemberDecorate %type_PushConstant_PushConstants 5 Offset 20
               OpMemberDecorate %type_PushConstant_PushConstants 6 Offset 24
               OpMemberDecorate %type_PushConstant_PushConstants 7 Offset 28
               OpMemberDecorate %type_PushConstant_PushConstants 8 Offset 32
               OpMemberDecorate %type_PushConstant_PushConstants 9 Offset 36
               OpMemberDecorate %type_PushConstant_PushConstants 10 Offset 40
               OpMemberDecorate %type_PushConstant_PushConstants 11 Offset 44
               OpDecorate %type_PushConstant_PushConstants Block
        %int = OpTypeInt 32 1
      %int_0 = OpConstant %int 0
      %int_2 = OpConstant %int 2
      %int_4 = OpConstant %int 4
      %int_5 = OpConstant %int 5
      %float = OpTypeFloat 32
%float_0_00200000009 = OpConstant %float 0.00200000009
%float_0_150000006 = OpConstant %float 0.150000006
%float_0_449999988 = OpConstant %float 0.449999988
       %uint = OpTypeInt 32 0
   %uint_131 = OpConstant %uint 131
  %float_0_5 = OpConstant %float 0.5
    %v2float = OpTypeVector %float 2
         %21 = OpConstantComposite %v2float %float_0_5 %float_0_5
    %float_0 = OpConstant %float 0
         %23 = OpConstantComposite %v2float %float_0 %float_0
     %uint_1 = OpConstant %uint 1
      %int_6 = OpConstant %int 6
    %uint_15 = OpConstant %uint 15
%uint_2246822507 = OpConstant %uint 2246822507
    %uint_13 = OpConstant %uint 13
%uint_16777215 = OpConstant %uint 16777215
%type_PushConstant_PushConstants = OpTypeStruct %float %float %uint %uint %uint %uint %float %uint %float %uint %uint %uint
%_ptr_PushConstant_type_PushConstant_PushConstants = OpTypePointer PushConstant %type_PushConstant_PushConstants
%type_2d_image = OpTypeImage %float 2D 2 0 0 2 R32f
%_ptr_UniformConstant_type_2d_image = OpTypePointer UniformConstant %type_2d_image
     %v3uint = OpTypeVector %uint 3
%_ptr_Input_v3uint = OpTypePointer Input %v3uint
       %void = OpTypeVoid
         %35 = OpTypeFunction %void
     %v2uint = OpTypeVector %uint 2
%_ptr_PushConstant_uint = OpTypePointer PushConstant %uint
       %bool = OpTypeBool
%_ptr_PushConstant_float = OpTypePointer PushConstant %float
    %v4float = OpTypeVector %float 4
%push_constants = OpVariable %_ptr_PushConstant_type_PushConstant_PushConstants PushConstant
%density_texture = OpVariable %_ptr_UniformConstant_type_2d_image UniformConstant
%gl_GlobalInvocationID = OpVariable %_ptr_Input_v3uint Input
     %uint_0 = OpConstant %uint 0
%float_3_883219 = OpConstant %float 3.883219
%uint_1643403271 = OpConstant %uint 1643403271
%float_5_96046519en08 = OpConstant %float 5.96046519e-08
       %main = OpFunction %void None %35
         %45 = OpLabel
         %46 = OpLoad %v3uint %gl_GlobalInvocationID
               OpSelectionMerge %47 None
               OpSwitch %uint_0 %48
         %48 = OpLabel
         %49 = OpCompositeExtract %uint %46 0
         %50 = OpAccessChain %_ptr_PushConstant_uint %push_constants %int_2
         %51 = OpLoad %uint %50
         %52 = OpUGreaterThanEqual %bool %49 %51
               OpSelectionMerge %53 None
               OpBranchConditional %52 %54 %53
         %54 = OpLabel
               OpBranch %47
         %53 = OpLabel
         %55 = OpAccessChain %_ptr_PushConstant_uint %push_constants %int_4
         %56 = OpLoad %uint %55
         %57 = OpAccessChain %_ptr_PushConstant_uint %push_constants %int_5
         %58 = OpLoad %uint %57
         %59 = OpConvertUToF %float %49
         %60 = OpFMul %float %59 %float_3_883219
         %61 = OpAccessChain %_ptr_PushConstant_float %push_constants %int_0
         %62 = OpLoad %float %61
         %63 = OpFMul %float %62 %float_0_00200000009
         %64 = OpFAdd %float %60 %63
         %65 = OpIMul %uint %49 %uint_131
         %66 = OpIMul %uint %49 %uint_1643403271
         %67 = OpBitwiseXor %uint %65 %66
         %68 = OpShiftRightLogical %uint %67 %uint_15
         %69 = OpBitwiseXor %uint %67 %68
         %70 = OpIMul %uint %69 %uint_2246822507
         %71 = OpShiftRightLogical %uint %70 %uint_13
         %72 = OpBitwiseXor %uint %70 %71
         %73 = OpBitwiseAnd %uint %72 %uint_16777215
         %74 = OpConvertUToF %float %73
         %75 = OpFMul %float %74 %float_5_96046519en08
         %76 = OpExtInst %float %1 FMix %float_0_150000006 %float_0_449999988 %75
         %77 = OpExtInst %float %1 Cos %64
         %78 = OpExtInst %float %1 Sin %64
         %79 = OpCompositeConstruct %v2float %77 %78
         %80 = OpVectorTimesScalar %v2float %79 %76
         %81 = OpFAdd %v2float %21 %80
         %82 = OpConvertUToF %float %56
         %83 = OpConvertUToF %float %58
         %84 = OpCompositeConstruct %v2float %82 %83
         %85 = OpFMul %v2float %81 %84
         %86 = OpISub %uint %56 %uint_1
         %87 = OpConvertUToF %float %86
         %88 = OpISub %uint %58 %uint_1
         %89 = OpConvertUToF %float %88
         %90 = OpCompositeConstruct %v2float %87 %89
         %91 = OpExtInst %v2float %1 FClamp %85 %23 %90
         %92 = OpConvertFToU %v2uint %91
         %93 = OpLoad %type_2d_image %density_texture
         %94 = OpImageRead %v4float %93 %92 None
         %95 = OpCompositeExtract %float %94 0
         %96 = OpAccessChain %_ptr_PushConstant_float %push_constants %int_6
         %97 = OpLoad %float %96
         %98 = OpFAdd %float %95 %97
         %99 = OpLoad %type_2d_image %density_texture
               OpImageWrite %99 %92 %98 None
               OpBranch %47
         %47 = OpLabel
               OpReturn
               OpFunctionEnd
